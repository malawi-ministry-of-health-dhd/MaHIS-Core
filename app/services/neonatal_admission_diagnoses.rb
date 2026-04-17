# frozen_string_literal: true

# Neonatal admission / discharge diagnosis allow-list backed by OpenMRS concept set
# "Neonatal admission diagnoses". Members are resolved at runtime from concept_set.
module NeonatalAdmissionDiagnoses
  SET_NAME = 'Neonatal admission diagnoses'

  # Canonical concept names (ConceptName.name) for members — matches frontend resolution / dictionary
  MEMBER_CANONICAL_NAMES = [
    'Abscess', 'Anaemia', 'Bowel Obstruction', 'Birth Injury/Trauma', 'Congenital Abnormality',
    'Congenital Heart Disease', 'Dehydration', 'Difficulty Feeding', 'Abandoned Baby',
    'HIV Low Risk', 'HIV High Risk', 'HIV Unknown',
    'Hypoglycaemia Not Symptomatic', 'Hypoglycaemia Symptomatic', 'At Risk Hypoglycaemia',
    'Gastroschisis', 'Possible Meconium Aspiration', 'Suspected Neonatal Sepsis', 'Risk Factors Sepsis',
    'Prematurity Respiratory Distress', 'Physiological Jaundice', 'TTN', 'Umbilical Hernia',
    'Meningitis', 'Ambiguous Genitalia', 'Apnoea Prematurity', 'Low Birth Weight',
    'Very Low Birth Weight', 'Extremely Low Birth Weight', 'Very Premature', 'Extremely Premature',
    'Convulsions', 'Mild Hypothermia', 'Moderate Hypothermia', 'Severe Hypothermia', 'Hyperthermia',
    'Term Respiratory Distress', 'Pathological Jaundice', 'HIE Birth Asphyxia', 'Suspected HIE',
    'Prolonged Jaundice', 'Cleft Lip Palate', 'Cleft Lip', 'Myelomeningocele', 'Omphalocele', 'CDH',
    'Mild Talipes', 'Moderate Talipes', 'Pneumonia', 'Bronchiolitis', 'Syphilis Exposed',
    'Suspected Congenital Syphilis', 'Hydrocephalus', 'Microcephaly', 'Fracture',
    'Tracheoesphageal Fistula', 'Born Before Arrival', 'Normal Baby', 'Necrotising Enterocolitis',
    'Meconium Exposure', 'Premature', 'Safekeeping', 'High Birth Weight', 'Haemorrhagic Disease',
    'Malaria', 'Other'
  ].freeze

  DIAGNOSIS_ENCOUNTER_NAMES = ['DIAGNOSIS', 'NEONATAL DIAGNOSIS'].freeze

  class << self
    def concept_set_concept_id
      ConceptName.find_by(name: SET_NAME, voided: 0)&.concept_id
    end

    def member_concept_ids
      set_id = concept_set_concept_id
      return [] unless set_id

      ConceptSet.where(concept_set: set_id).distinct.pluck(:concept_id)
    end

    def primary_diagnosis_concept_id
      @primary_diagnosis_concept_id ||= ConceptName.find_by(name: 'Primary diagnosis', voided: 0)&.concept_id
    end

    def secondary_diagnosis_concept_id
      @secondary_diagnosis_concept_id ||= ConceptName.find_by(name: 'Secondary diagnosis', voided: 0)&.concept_id
    end

    def applies_encounter?(encounter)
      return false unless encounter&.program&.name&.match?(/neonatal/i)

      type_name = encounter.type&.name
      return false if type_name.blank?

      u = type_name.upcase
      return true if DIAGNOSIS_ENCOUNTER_NAMES.include?(u)
      return true if u.match?(/NEONATAL.*DISCHARGE/)

      false
    end

    def diagnosis_checkpoint_encounter?(encounter)
      u = encounter&.type&.name&.upcase
      u.present? && DIAGNOSIS_ENCOUNTER_NAMES.include?(u)
    end

    # Raises InvalidParameterError when a neonatal diagnosis observation violates the allow-list
    def validate_observation!(encounter, obs_parameters)
      return unless applies_encounter?(encounter)

      allowed = member_concept_ids
      if allowed.blank?
        Rails.logger.warn('[NeonatalAdmissionDiagnoses] Concept set empty or missing; skipping validation')
        return
      end

      cid = obs_parameters[:concept_id].to_i
      vc = obs_parameters[:value_coded].presence&.to_i
      primary_id = primary_diagnosis_concept_id
      secondary_id = secondary_diagnosis_concept_id
      group_id = obs_parameters[:obs_group_id].presence&.to_i

      # Discharge (and similar): Primary diagnosis question with coded answer
      if primary_id.present? && cid == primary_id && vc.present? && vc != primary_id
        raise InvalidParameterError, 'Primary diagnosis must be one of the neonatal admission diagnoses' unless allowed.include?(vc)

        return
      end

      # Discharge: Secondary diagnosis question with coded answer
      if secondary_id.present? && cid == secondary_id && vc.present? && vc != secondary_id
        raise InvalidParameterError, 'Secondary diagnosis must be one of the neonatal admission diagnoses' unless allowed.include?(vc)

        return
      end

      # Checkpoint flow: grouped observations — diagnosis stored as concept_id on child obs
      if group_id.present? && cid.positive? && diagnosis_checkpoint_encounter?(encounter)
        raise InvalidParameterError, 'Diagnosis must be one of the neonatal admission diagnoses' unless allowed.include?(cid)

        return
      end

      # Parent row for diagnosis grouping (self-coded container) — allow
      return if primary_id.present? && cid == primary_id && vc == primary_id
      return if secondary_id.present? && cid == secondary_id && vc == secondary_id

      nil
    end

  end

  # Idempotent: creates set concept, member concepts if missing, and concept_set rows
  class Seeder
    class << self
      def seed!
        ActiveRecord::Base.transaction do
          set_concept = ensure_set_concept!
          Rails.logger.info("[NeonatalAdmissionDiagnoses] Set concept_id=#{set_concept.concept_id}")

          linked = 0
          created = 0
          MEMBER_CANONICAL_NAMES.each do |name|
            member = find_or_create_member_concept!(name)
            created += 1 if member[:created]
            link_member!(set_concept.concept_id, member[:concept].concept_id)
            linked += 1
          end

          Rails.logger.info("[NeonatalAdmissionDiagnoses] Linked #{linked} members (#{created} new concepts created)")
        end
      end

      private

      def creator_id
        @creator_id ||= User.unscoped.order(:user_id).pick(:user_id) || 1
      end

      def ensure_set_concept!
        existing = Concept.find_by_name(SET_NAME)
        return existing if existing

        datatype = ConceptDatatype.find_by(name: 'N/A') || ConceptDatatype.find_by(name: 'Coded')
        klass = ConceptClass.find_by(name: 'Conv') || ConceptClass.find_by(name: 'Question') || ConceptClass.find_by(name: 'Misc')
        raise 'Missing concept_datatype or concept_class for neonatal set' unless datatype && klass

        concept = Concept.create!(
          datatype_id: datatype.concept_datatype_id,
          class_id: klass.concept_class_id,
          creator: creator_id,
          date_created: Time.zone.now,
          retired: 0,
          is_set: 1,
          uuid: SecureRandom.uuid
        )
        ConceptName.create!(
          concept_id: concept.concept_id,
          name: SET_NAME,
          locale: 'en',
          locale_preferred: 1,
          concept_name_type: 'FULLY_SPECIFIED',
          creator: creator_id,
          date_created: Time.zone.now,
          voided: 0,
          uuid: SecureRandom.uuid
        )
        concept
      end

      def find_or_create_member_concept!(name)
        existing = Concept.find_by_name(name)
        return { concept: existing, created: false } if existing

        datatype = ConceptDatatype.find_by(name: 'N/A') || ConceptDatatype.find_by(name: 'Coded')
        klass = ConceptClass.find_by(name: 'Diagnosis') || ConceptClass.find_by(name: 'Misc')
        raise "Missing datatype/class for member #{name}" unless datatype && klass

        concept = Concept.create!(
          datatype_id: datatype.concept_datatype_id,
          class_id: klass.concept_class_id,
          creator: creator_id,
          date_created: Time.zone.now,
          retired: 0,
          is_set: 0,
          uuid: SecureRandom.uuid
        )
        ConceptName.create!(
          concept_id: concept.concept_id,
          name: name,
          locale: 'en',
          locale_preferred: 1,
          concept_name_type: 'FULLY_SPECIFIED',
          creator: creator_id,
          date_created: Time.zone.now,
          voided: 0,
          uuid: SecureRandom.uuid
        )
        { concept: concept, created: true }
      end

      def link_member!(set_concept_id, member_concept_id)
        return if ConceptSet.exists?(concept_set: set_concept_id, concept_id: member_concept_id)

        ConceptSet.create!(
          concept_set: set_concept_id,
          concept_id: member_concept_id,
          creator: creator_id,
          date_created: Time.zone.now,
          uuid: SecureRandom.uuid
        )
      end
    end
  end
end
