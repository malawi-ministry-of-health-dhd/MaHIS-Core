# frozen_string_literal: true

# Repairs mojibake in concept names that arrives with the upstream metadata.
#
# The metadata published by the concept server stores some names double-encoded:
# the UTF-8 bytes were read back as ISO-8859-1 once (the OpenMRS 1.9 / Tomcat
# request layer, whose servlet default is ISO-8859-1) and then as MySQL's latin1
# three more times (MySQL's latin1 is Windows-1252, except 0x81 0x8D 0x8F 0x90
# 0x9D pass through as control characters — those surviving bytes are what
# identify the database as the source of the later passes).
#
#   "cNa⁺ (mmol/L)"  ->  "cNaÃƒÆ’Ã‚Â¢Ãƒâ€šÃ‚Â\x81Ãƒâ€šÃ‚Âº (mmol/L)"
#
# The frontend resolves these concepts by name, so while a name is corrupted the
# AETC bedside results form cannot label the field from the dictionary and any
# obs or lab order keyed on it fails to resolve.
#
# This file only defines the repair. It is invoked from db/seeds.rb AFTER the
# metadata import — every seed re-imports metadata.sql and reintroduces the
# corruption — and can also be run on its own, without a full reseed, with:
#
#   bundle exec rake concepts:repair_names
#
# Scope: the AETC bedside blood-gas panel only. 190 concept names, 59 location
# names and 2 drug names are affected in total — the rest are left until someone
# decides how to handle them, and several are duplicate pairs that need
# de-duplicating rather than renaming.
#
# The real fix belongs upstream on the concept server. This is a stopgap that
# keeps the bedside form working across reseeds.
module ConceptNameRepairs
  # The names this repair is responsible for, keyed by concept_name_id.
  # concept_name_id values are explicit in metadata.sql, so they are stable
  # across seeds.
  CORRECTIONS = {
    38_501 => 'cK⁺ (mmol/L)',
    49_504 => 'pCO₂ (mmHg)',
    49_506 => 'pO₂ (mmHg)',
    49_510 => 'cHCO₃⁻ (P,st)c',
    49_516 => 'sO₂ (%)',
    49_518 => 'FO₂Hb (%)',
    49_522 => 'cNa⁺ (mmol/L)',
    49_524 => 'cCa²⁺ (mmol/L)',
    49_526 => 'cCl⁻ (mmol/L)',
    51_178 => 'pO₂ (T) mmHg',
    51_184 => 'ctBil (µmol/L)',
    51_188 => 'pCO₂ (T) mmHg'
  }.freeze

  # concept_name 51190 (concept 50524) is a truncated duplicate of 49510 and
  # decodes to the same "cHCO₃⁻ (P,st)c". Repairing it would leave two live
  # concepts sharing one name and make lookup by name ambiguous, so it is left
  # corrupted — and therefore unreachable — until that concept is retired.
  KNOWN_DUPLICATE_IDS = [51_190].freeze

  # MySQL's latin1: Windows-1252, except these five bytes (undefined in cp1252)
  # pass through as the matching C1 control characters.
  CP1252_UNDEFINED = [0x81, 0x8D, 0x8F, 0x90, 0x9D].freeze

  MYSQL_LATIN1 = (0..255).map do |byte|
    if CP1252_UNDEFINED.include?(byte)
      byte.chr(Encoding::UTF_8)
    else
      [byte].pack('C').force_encoding('WINDOWS-1252').encode('UTF-8')
    end
  end.freeze

  module_function

  # One pass of "these UTF-8 bytes were read as ISO-8859-1".
  def as_iso8859_1(text)
    text.encode('UTF-8').b.force_encoding('ISO-8859-1').encode('UTF-8')
  end

  # One pass of "these UTF-8 bytes were read as MySQL latin1".
  def as_mysql_latin1(text)
    text.encode('UTF-8').b.bytes.map { |byte| MYSQL_LATIN1[byte] }.join
  end

  # The exact corruption chain, verified to reproduce all 12 stored names byte
  # for byte. Used to recognise a corrupted row rather than guessing from a
  # marker character, so the repair can only ever match what it expects.
  def corrupted_form(correct_name)
    3.times.reduce(as_iso8859_1(correct_name)) { |text, _| as_mysql_latin1(text) }
  end

  def run!(logger: $stdout)
    repaired = 0
    already_correct = 0
    notes = []
    connection = ActiveRecord::Base.connection

    CORRECTIONS.each do |concept_name_id, correct_name|
      row = connection.select_one(
        ActiveRecord::Base.sanitize_sql_array(
          ['SELECT concept_id, name FROM concept_name WHERE concept_name_id = ? AND voided = 0', concept_name_id]
        )
      )

      if row.nil?
        notes << "#{concept_name_id}: no live row (metadata may have renumbered it)"
        next
      end

      stored = row['name'].to_s.dup.force_encoding('UTF-8')

      if stored == correct_name
        already_correct += 1
        next
      end

      # Only touch a row holding exactly the corruption we know about. Anything
      # else is someone's edit and is left alone. Compared in Ruby on purpose:
      # the column collates utf8mb3_general_ci, under which a SQL comparison
      # against 'Ã' also matches a plain 'a'.
      unless stored == corrupted_form(correct_name)
        notes << "#{concept_name_id}: unexpected value #{stored.inspect} — left alone"
        next
      end

      taken = connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          ['SELECT COUNT(*) FROM concept_name WHERE voided = 0 AND name = ? AND concept_id <> ?',
           correct_name, row['concept_id']]
        )
      ).to_i

      if taken.positive?
        notes << "#{concept_name_id}: #{correct_name.inspect} already belongs to another concept — left alone"
        next
      end

      connection.execute(
        ActiveRecord::Base.sanitize_sql_array(
          ['UPDATE concept_name SET name = ? WHERE concept_name_id = ?', correct_name, concept_name_id]
        )
      )
      repaired += 1
    end

    logger.puts "Concept name repairs: #{repaired} repaired, #{already_correct} already correct, " \
                "#{KNOWN_DUPLICATE_IDS.size} duplicate(s) intentionally skipped"
    notes.each { |note| logger.puts "  #{note}" }

    { repaired: repaired, already_correct: already_correct, notes: notes }
  end
end
