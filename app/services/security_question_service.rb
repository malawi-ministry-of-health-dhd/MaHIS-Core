# frozen_string_literal: true

##
# Security questions a user answers to reset a forgotten password.
#
# Storage deliberately reuses `user_property`, the table that already holds
# per-user secrets in this schema (`last_used_password_1..6` keep SHA512 password
# hashes there). Answers are hashed exactly the way passwords are -
# UserService.hash_password, i.e. SHA512 over answer + the user's own salt - so a
# database read never reveals an answer, and the same salt rotation applies.
#
# The three chosen questions and their hashed answers live in ONE property as
# JSON, mirroring how `current_supervision_session` stores a JSON payload.
module SecurityQuestionService
  ANSWERS_PROPERTY = 'security_questions'
  RESET_PROPERTY = 'security_question_reset'

  # Properties that must never be readable or writable through the generic
  # user-properties endpoints - see UserPropertiesController.
  PROTECTED_PROPERTIES = [ANSWERS_PROPERTY, RESET_PROPERTY].freeze

  REQUIRED_ANSWERS = 3
  # How many of the three must match to prove identity. Two is a deliberate
  # allowance for a half-remembered answer; it also means an attacker needs only
  # two of the three, which is why the reset endpoints stay throttled per
  # username and the token they yield can do nothing but set a password.
  MINIMUM_CORRECT_ANSWERS = 2
  MINIMUM_ANSWER_LENGTH = 2
  RESET_TOKEN_VALIDITY = 10.minutes

  # Ten to choose from, everyday and personal for Malawi and the wider region.
  # Ids are stored, never the text, so wording can be corrected later without
  # invalidating anyone's saved answers.
  CATALOGUE = [
    { id: 'birth_village', text: 'What is the name of the village where you were born?' },
    { id: 'mother_maiden_name', text: "What is your mother's maiden (family) name?" },
    { id: 'first_primary_school', text: 'What was the name of your first primary school?' },
    { id: 'home_district', text: 'What is the name of your home district?' },
    { id: 'father_home_village', text: "What is your father's home village?" },
    { id: 'childhood_best_friend', text: 'What was the name of your best friend in primary school?' },
    { id: 'childhood_church', text: 'What is the name of the church or mosque you attended as a child?' },
    { id: 'first_animal', text: 'What was the name of your first pet or farm animal?' },
    { id: 'childhood_food', text: 'What was your favourite food as a child?' },
    { id: 'family_market', text: 'What is the name of the market your family shopped at when you were growing up?' }
  ].freeze

  CATALOGUE_BY_ID = CATALOGUE.index_by { |question| question[:id] }.freeze

  class InvalidAnswers < InvalidParameterError; end

  class << self
    def catalogue
      CATALOGUE.map { |question| question.dup }
    end

    def configured?(user)
      stored_answers(user).size == REQUIRED_ANSWERS
    end

    ##
    # The questions this user chose, in the order they chose them. Never returns
    # anything derived from the answers.
    def questions_for(user)
      stored_answers(user).filter_map do |entry|
        question = CATALOGUE_BY_ID[entry['question_id']]
        next unless question

        { id: question[:id], text: question[:text] }
      end
    end

    ##
    # Replaces the user's set. `entries` is [{ question_id:, answer: }, ...] and
    # must name exactly REQUIRED_ANSWERS distinct catalogue questions.
    def save!(user, entries)
      normalized = normalize_entries(entries)
      raise InvalidAnswers, "Choose exactly #{REQUIRED_ANSWERS} questions" unless normalized.size == REQUIRED_ANSWERS

      question_ids = normalized.map { |entry| entry[:question_id] }
      raise InvalidAnswers, 'Choose three different questions' unless question_ids.uniq.size == REQUIRED_ANSWERS

      unknown = question_ids.reject { |id| CATALOGUE_BY_ID.key?(id) }
      raise InvalidAnswers, "Unknown question: #{unknown.join(', ')}" if unknown.any?

      payload = normalized.map do |entry|
        answer = entry[:answer]
        raise InvalidAnswers, "Answers must be at least #{MINIMUM_ANSWER_LENGTH} characters" \
          if answer.length < MINIMUM_ANSWER_LENGTH

        { 'question_id' => entry[:question_id], 'answer' => hash_answer(user, answer) }
      end

      write_property(user, ANSWERS_PROPERTY, payload.to_json)
      questions_for(user)
    end

    ##
    # True when at least MINIMUM_CORRECT_ANSWERS of the stored questions are
    # answered correctly. All three must still be submitted - a caller cannot
    # improve their odds by answering only the two they are sure of.
    #
    # Comparison is over the hashes, and the count is never reported back, so a
    # failed attempt reveals neither which answers were right nor how close it
    # came.
    def verify(user, entries)
      correct_answers(user, entries) >= MINIMUM_CORRECT_ANSWERS
    end

    ##
    # How many stored questions the supplied answers match. Zero unless the user
    # has a full set and every one of them was attempted.
    def correct_answers(user, entries)
      stored = stored_answers(user)
      return 0 unless stored.size == REQUIRED_ANSWERS

      supplied = normalize_entries(entries).index_by { |entry| entry[:question_id] }
      return 0 unless stored.all? { |entry| supplied.key?(entry['question_id']) }

      stored.count do |entry|
        answer = supplied[entry['question_id']][:answer]
        answer.present? && secure_equals?(entry['answer'], hash_answer(user, answer))
      end
    end

    def clear!(user)
      UserProperty.where(user_id: user.user_id, property: PROTECTED_PROPERTIES).delete_all
    end

    ##
    # A single-use, short-lived token that authorises ONE password change and
    # nothing else. Only its hash is stored, exactly as for the answers, so the
    # database copy cannot be replayed.
    def issue_reset_token!(user)
      token = SecureRandom.urlsafe_base64(32)
      write_property(
        user, RESET_PROPERTY,
        { 'token' => hash_answer(user, token), 'expires_at' => (Time.current + RESET_TOKEN_VALIDITY).iso8601 }.to_json
      )

      { token:, expires_in: RESET_TOKEN_VALIDITY.to_i }
    end

    ##
    # Returns the user the token belongs to, or nil. Consumes the token either
    # way it is spent - a token is good for one attempt.
    def consume_reset_token!(token)
      return nil if token.blank?

      # The token carries no user id, so every live reset row is a candidate.
      # There are only ever a handful, and each check is a single hash.
      UserProperty.where(property: RESET_PROPERTY).find_each do |property|
        payload = parse_json(property.property_value)
        next if payload.blank?

        user = User.unscoped.find_by(user_id: property.user_id)
        next unless user

        next unless secure_equals?(payload['token'].to_s, hash_answer(user, token))

        property.delete
        return nil if expired?(payload['expires_at'])

        return user
      end

      nil
    end

    private

    def hash_answer(user, answer)
      raise InvalidAnswers, 'User has no salt to hash against' if user.salt.blank?

      UserService.hash_password(answer, user.salt)
    end

    # Case and spacing must not decide whether someone gets back into their
    # account: "Blantyre", " blantyre" and "BLANTYRE " are the same answer.
    def normalize_entries(entries)
      Array(entries).filter_map do |entry|
        entry = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry
        question_id = (entry['question_id'] || entry[:question_id]).to_s.strip
        answer = (entry['answer'] || entry[:answer]).to_s.strip.downcase.gsub(/\s+/, ' ')
        next if question_id.blank? || answer.blank?

        { question_id:, answer: }
      end
    end

    def stored_answers(user)
      property = UserProperty.find_by(user_id: user.user_id, property: ANSWERS_PROPERTY)
      entries = parse_json(property&.property_value)
      return [] unless entries.is_a?(Array)

      entries.select { |entry| entry.is_a?(Hash) && entry['question_id'].present? && entry['answer'].present? }
    end

    def expired?(expires_at)
      # Time.zone.parse returns nil for unparseable input rather than raising,
      # so an unreadable expiry must be treated as expired, not as no expiry.
      parsed = Time.zone.parse(expires_at.to_s)
      parsed.nil? || parsed <= Time.current
    rescue ArgumentError, TypeError
      true
    end

    def parse_json(value)
      return nil if value.blank?

      JSON.parse(value)
    rescue JSON::ParserError
      nil
    end

    # Length-independent comparison of two hex digests.
    def secure_equals?(left, right)
      ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
    rescue ArgumentError
      false
    end

    def write_property(user, property, value)
      record = UserProperty.find_or_initialize_by(user_id: user.user_id, property:)
      record.user = user
      record.property_value = value
      record.save!
    end
  end
end
