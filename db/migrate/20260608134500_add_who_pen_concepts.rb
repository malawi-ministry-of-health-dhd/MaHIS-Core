# frozen_string_literal: true

class AddWhoPenConcepts < ActiveRecord::Migration[8.1]
  def up
    # Set current user context for Auditable trail
    User.current = User.first

    coded_datatype = ConceptDatatype.find_by(name: 'Coded') || ConceptDatatype.where('LOWER(name) = ?', 'coded').first
    question_class = ConceptClass.find_by(name: 'Question') || ConceptClass.where('LOWER(name) = ?', 'question').first
    na_datatype = ConceptDatatype.find_by(name: 'N/A') || ConceptDatatype.where('LOWER(name) = ?', 'n/a').first
    misc_class = ConceptClass.find_by(name: 'Misc') || ConceptClass.where('LOWER(name) = ?', 'misc').first

    raise "Coded datatype not found" unless coded_datatype
    raise "Question class not found" unless question_class
    raise "N/A datatype not found" unless na_datatype
    raise "Misc class not found" unless misc_class

    # 1. "WHO PEN" (Question concept)
    who_pen_concept = find_or_create_concept('WHO PEN', question_class.concept_class_id, coded_datatype.concept_datatype_id)

    # 2. "PEN" (Answer concept)
    pen_concept = find_or_create_concept('PEN', misc_class.concept_class_id, na_datatype.concept_datatype_id)

    # 3. "PEN-Plus" (Answer concept)
    pen_plus_concept = find_or_create_concept('PEN-Plus', misc_class.concept_class_id, na_datatype.concept_datatype_id)

    # Link answers to question
    add_concept_answer(who_pen_concept.id, pen_concept.id)
    add_concept_answer(who_pen_concept.id, pen_plus_concept.id)

    # Rebuild concept words search index
    rebuild_concept_words
  end

  def down
    User.current = User.first

    who_pen = ConceptName.find_by(name: 'WHO PEN')&.concept
    pen = ConceptName.find_by(name: 'PEN')&.concept
    pen_plus = ConceptName.find_by(name: 'PEN-Plus')&.concept

    if who_pen
      ConceptAnswer.where(concept_id: who_pen.id).delete_all
      ConceptName.where(concept_id: who_pen.id).delete_all
      who_pen.destroy
    end

    if pen
      ConceptName.where(concept_id: pen.id).delete_all
      pen.destroy
    end

    if pen_plus
      ConceptName.where(concept_id: pen_plus.id).delete_all
      pen_plus.destroy
    end

    rebuild_concept_words
  end

  private

  def find_or_create_concept(name, class_id, datatype_id)
    concept_name = ConceptName.find_by(name: name, voided: false)
    if concept_name
      return concept_name.concept
    end

    creator_id = User.current&.id || 1

    concept = Concept.create!(
      class_id: class_id,
      datatype_id: datatype_id,
      creator: creator_id,
      date_created: Time.now,
      retired: false,
      uuid: SecureRandom.uuid
    )

    ConceptName.create!(
      concept_id: concept.id,
      name: name,
      locale: 'en',
      locale_preferred: true,
      concept_name_type: 'FULLY_SPECIFIED',
      creator: creator_id,
      date_created: Time.now,
      uuid: SecureRandom.uuid,
      voided: false
    )

    concept
  end

  def add_concept_answer(question_concept_id, answer_concept_id)
    existing = ConceptAnswer.find_by(concept_id: question_concept_id, answer_concept: answer_concept_id)
    return if existing

    creator_id = User.current&.id || 1

    ConceptAnswer.create!(
      concept_id: question_concept_id,
      answer_concept: answer_concept_id,
      creator: creator_id,
      date_created: Time.now,
      uuid: SecureRandom.uuid
    )
  end

  def rebuild_concept_words
    # Clean up and rebuild search words index for our target concepts
    ['WHO PEN', 'PEN', 'PEN-Plus'].each do |name|
      cn = ConceptName.find_by(name: name, voided: false)
      next unless cn

      ActiveRecord::Base.connection.execute("DELETE FROM concept_word WHERE concept_name_id = #{cn.id}")

      phrase = cn.name
      normalized_phrase = phrase.to_s.gsub(/[!"\#$%&'()*,+\-.\/:;<=>?@\[\]\\^_`{|}~]/, ' ')
      parts = normalized_phrase.strip.tr("\n", ' ').split.map(&:strip).map(&:upcase).uniq

      parts.each do |word|
        next if word.blank?
        next if %w[A AND AT BUT BY FOR HAS OF THE TO].include?(word)

        ActiveRecord::Base.connection.execute(
          "INSERT INTO concept_word (concept_id, word, locale, concept_name_id, weight) " \
          "VALUES (#{cn.concept_id}, '#{word[0, 50]}', 'en', #{cn.id}, 1.0)"
        )
      end
    end
  end
end
