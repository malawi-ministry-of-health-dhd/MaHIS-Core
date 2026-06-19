class PotentialDuplicateFinderService
  require 'bantu_soundex'

  # Attributes compared (in order) when scoring how similar two people are.
  MATCH_PARAMS = %i[given_name family_name gender birthdate home_village
                    home_traditional_authority home_district].freeze

  # Attributes that must match exactly for a soundex (sounds-alike) duplicate.
  SOUNDEX_MATCH_PARAMS = %i[home_village home_traditional_authority home_district].freeze

  DEFAULT_THRESHOLD = 85         # used when config/application.yml has no deduplication entry
  CANDIDATE_BATCH_SIZE = 1000    # rows loaded per DB round-trip
  LARGE_BLOCK_WARNING = 2000     # log a warning past this block size (still processed, never dropped)

  # Lightweight in-memory representation of a patient. Carrying these instead of
  # full ActiveRecord objects keeps the O(pairs) comparison loop cheap, and the
  # fingerprints/soundex keys are precomputed once per patient rather than on
  # every comparison.
  Candidate = Struct.new(
    :person_id, :gender, :birthdate,
    :given_name, :middle_name, :family_name,
    :home_village, :home_traditional_authority, :home_district,
    :fingerprint,       # normalised concat of MATCH_PARAMS, scored with WhiteSimilarity
    :home_fingerprint,  # normalised home attributes, nil when entirely blank
    :given_sx, :middle_sx, :family_sx,
    keyword_init: true
  )

  class << self
    # Scan the WHOLE patient database (every program) for potential duplicates,
    # persist newly found pairs, and return the matches that were detected.
    def duplicates_finder
      candidates = load_candidates
      Rails.logger.info("[dedup] loaded #{candidates.size} patients")
      return [] if candidates.size < 2

      pairs = candidate_pairs(candidates)
      Rails.logger.info("[dedup] comparing #{pairs.size} candidate pair(s) after blocking")

      matches = score_pairs(pairs)
      save_matching(matches)
      matches
    end

    private

    # ---- 1. Load every (non-voided) patient, one row per person --------------
    def load_candidates
      seen = {}
      base_query.find_each(batch_size: CANDIDATE_BATCH_SIZE) do |row|
        # A person can have several non-voided names/addresses, which the joins
        # turn into multiple rows; keep the first and ignore the rest.
        next if seen.key?(row.person_id)

        seen[row.person_id] = build_candidate(row)
      end
      seen.values
    end

    # No program filter -> the whole system. voided = 0 is applied automatically
    # by VoidableRecord's default scope on every joined table.
    def base_query
      Person.joins(:names, :addresses, :patient)
            .select(<<~SQL.squish)
              person.person_id, person.birthdate, person.gender,
              person_name.given_name, person_name.family_name, person_name.middle_name,
              person_address.address2          AS home_district,
              person_address.neighborhood_cell AS home_village,
              person_address.county_district   AS home_traditional_authority
            SQL
    end

    def build_candidate(row)
      home_parts = SOUNDEX_MATCH_PARAMS.map { |attr| normalize(row.send(attr)) }

      Candidate.new(
        person_id: row.person_id,
        gender: normalize(row.gender),
        birthdate: row.birthdate,
        given_name: row.given_name,
        middle_name: row.middle_name,
        family_name: row.family_name,
        home_village: row.home_village,
        home_traditional_authority: row.home_traditional_authority,
        home_district: row.home_district,
        fingerprint: MATCH_PARAMS.map { |attr| normalize(row.send(attr)) }.join,
        home_fingerprint: home_parts.any?(&:present?) ? home_parts.join('|') : nil,
        given_sx: soundex(row.given_name),
        middle_sx: soundex(row.middle_name),
        family_sx: soundex(row.family_name)
      )
    end

    # ---- 2. Blocking: only compare patients that share a blocking key --------
    # This is what turns an O(n^2) scan of the whole database into O(sum of
    # block^2). Patients are bucketed by phonetic name and by demographics; we
    # only ever compare within a bucket, then de-duplicate pairs globally.
    def candidate_pairs(candidates)
      buckets = Hash.new { |hash, key| hash[key] = [] }
      candidates.each do |candidate|
        blocking_keys(candidate).each { |key| buckets[key] << candidate }
      end

      seen_pairs = Set.new
      pairs = []
      buckets.each do |key, members|
        next if members.size < 2

        if members.size > LARGE_BLOCK_WARNING
          Rails.logger.warn("[dedup] large block #{key} has #{members.size} members")
        end

        members.combination(2) do |a, b|
          id_pair = a.person_id < b.person_id ? [a.person_id, b.person_id] : [b.person_id, a.person_id]
          pairs << [a, b] if seen_pairs.add?(id_pair)
        end
      end
      pairs
    end

    # A patient lands in several buckets so a duplicate is found even when one
    # field is mistyped:
    #   P - both names sound alike (catches address/dob typos)
    #   D - same gender + birthdate + surname sound (catches given-name typos)
    #   G - same gender + birthdate + given-name sound (catches surname typos)
    def blocking_keys(candidate)
      keys = []
      keys << "P:#{candidate.family_sx}:#{candidate.given_sx}" if candidate.family_sx || candidate.given_sx
      if candidate.birthdate
        keys << "D:#{candidate.gender}:#{candidate.birthdate}:#{candidate.family_sx}" if candidate.family_sx
        keys << "G:#{candidate.gender}:#{candidate.birthdate}:#{candidate.given_sx}" if candidate.given_sx
      end
      keys
    end

    # ---- 3. Score each unique pair -------------------------------------------
    def score_pairs(pairs)
      threshold = threshold_percent
      matches = []
      pairs.each do |a, b|
        similarity = white_similarity(a.fingerprint, b.fingerprint)
        fuzzy = similarity >= threshold
        soundex = sounds_like_same_person?(a, b)
        next unless fuzzy || soundex

        matches << {
          patient_id_a: a.person_id,
          patient_id_b: b.person_id,
          match_percentage: similarity,
          match_type: [('fuzzy' if fuzzy), ('soundex' if soundex)].compact.join('+')
        }
      end
      matches
    end

    # Names sound alike AND the home address matches exactly. (The previous
    # implementation compared `(string == string) == 100`, which was always
    # false, so this rule never actually fired.)
    def sounds_like_same_person?(a, b)
      a.given_sx && a.given_sx == b.given_sx &&
        a.family_sx && a.family_sx == b.family_sx &&
        a.middle_sx == b.middle_sx &&
        a.home_fingerprint && a.home_fingerprint == b.home_fingerprint
    end

    # ---- 4. Persist new pairs -------------------------------------------------
    def save_matching(matches)
      return if matches.empty?

      existing = existing_pairs
      fresh = matches.reject { |m| existing.include?([m[:patient_id_a], m[:patient_id_b]].minmax) }
      return if fresh.empty?

      ActiveRecord::Base.transaction do
        fresh.each do |match|
          PotentialDuplicate.create!(
            patient_id_a: match[:patient_id_a],
            patient_id_b: match[:patient_id_b],
            match_percentage: match[:match_percentage]
          )
        end
      end
      Rails.logger.info("[dedup] flagged #{fresh.size} new potential duplicate pair(s)")
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("[dedup] failed to save potential duplicates: #{e.message}")
    end

    # Load already-flagged pairs once (normalised, order-independent) instead of
    # issuing an EXISTS query per candidate match.
    def existing_pairs
      PotentialDuplicate.pluck(:patient_id_a, :patient_id_b)
                        .each_with_object(Set.new) { |(a, b), set| set << [a, b].minmax }
    end

    # ---- helpers --------------------------------------------------------------
    def white_similarity(a, b)
      return 0 if a.blank? || b.blank?

      (WhiteSimilarity.similarity(a, b) * 100).round
    rescue StandardError
      0
    end

    def normalize(value)
      value.to_s.downcase.strip
    end

    def soundex(value)
      text = value.to_s.strip
      return nil if text.empty?

      text.soundex
    rescue StandardError
      nil
    end

    def threshold_percent
      @threshold_percent ||= (application_config.dig('deduplication', 'match_percentage') || DEFAULT_THRESHOLD).to_i
    end

    def application_config
      @application_config ||= YAML.load_file(Rails.root.join('config/application.yml').to_s, aliases: true) || {}
    rescue StandardError => e
      Rails.logger.warn("[dedup] could not read application.yml (#{e.message}); using default threshold")
      {}
    end
  end
end
