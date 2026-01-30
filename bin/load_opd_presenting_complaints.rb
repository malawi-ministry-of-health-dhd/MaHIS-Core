# frozen_string_literal: true

class PresentingComplaintConceptExporter
  LOCALE = 'en'
  FULLY_SPECIFIED = 'FULLY_SPECIFIED'
  SHORT = 'SHORT'

  CONCEPT_CLASS = 'Finding'
  SET_CLASS = 'ConvSet'
  DATATYPE_NA = 'N/A'

  def initialize(user_id:)
    @user_id = user_id
    @now = Time.now
  end

  def run
    ActiveRecord::Base.transaction do
      root_concept = create_set_concept('Presenting Complaints')

      complaint_groups.each do |group_name, complaints|
        group_concept = create_set_concept(group_name)
        link_set(root_concept, group_concept)

        complaints.each do |complaint|
          complaint_concept = create_concept(complaint)
          link_set(group_concept, complaint_concept)
        end
      end
    end
  end

  private

  def complaint_groups
  {
    'General / Constitutional Complaints' => [
      'Fever',
      'Fatigue / Weakness',
      'Weight loss',
      'Weight gain',
      'Night sweats',
      'Loss of appetite',
      'General body pain',
      'Malaise'
    ],

    'Respiratory System' => [
      'Cough',
      'Shortness of breath / Difficulty breathing',
      'Chest tightness',
      'Wheezing',
      'Hemoptysis',
      'Sore throat',
      'Runny nose / Nasal congestion'
    ],

    'Cardiovascular System' => [
      'Chest pain',
      'Palpitations',
      'Swelling of legs (edema)',
      'Dizziness',
      'Fainting / Syncope',
      'High blood pressure symptoms'
    ],

    'Gastrointestinal System' => [
      'Abdominal pain',
      'Nausea',
      'Vomiting',
      'Diarrhea',
      'Constipation',
      'Blood in stool',
      'Heartburn',
      'Difficulty swallowing',
      'Abdominal bloating'
    ],

    'Genitourinary System' => [
      'Painful urination (dysuria)',
      'Frequent urination',
      'Blood in urine (hematuria)',
      'Lower abdominal pain',
      'Flank pain',
      'Urinary incontinence',
      'Reduced urine output'
    ],

    'Obstetric & Gynecological' => [
      'Lower abdominal / pelvic pain',
      'Vaginal bleeding',
      'Vaginal discharge',
      'Missed periods / Amenorrhea',
      'Painful menstruation',
      'Antenatal visit',
      'Postnatal complaints'
    ],

    'Musculoskeletal System' => [
      'Joint pain',
      'Back pain',
      'Muscle pain',
      'Joint swelling',
      'Reduced movement',
      'Injury / Trauma',
      'Bone pain'
    ],

    'Neurological System' => [
      'Headache',
      'Dizziness / Vertigo',
      'Seizures',
      'Weakness of limbs',
      'Numbness / Tingling',
      'Loss of consciousness',
      'Difficulty speaking',
      'Tremors'
    ],

    'Ear, Nose & Throat (ENT)' => [
      'Ear pain',
      'Ear discharge',
      'Hearing loss',
      'Sore throat',
      'Hoarseness',
      'Nose bleeding (epistaxis)',
      'Sinus pain'
    ],

    'Eye / Vision' => [
      'Red eye',
      'Eye pain',
      'Blurred vision',
      'Loss of vision',
      'Eye discharge',
      'Itching eyes',
      'Foreign body sensation'
    ],

    'Dermatological (Skin & Hair)' => [
      'Skin rash',
      'Itching (pruritus)',
      'Skin ulcers / wounds',
      'Swelling',
      'Hair loss',
      'Nail changes',
      'Burns'
    ],

    'Mental Health / Behavioral' => [
      'Anxiety',
      'Depression',
      'Sleep disturbances',
      'Confusion',
      'Substance use problems',
      'Behavioral changes',
      'Stress-related complaints'
    ],

    'Endocrine & Metabolic' => [
      'Excessive thirst',
      'Excessive urination',
      'Heat intolerance',
      'Cold intolerance',
      'Goiter / Neck swelling',
      'Unexplained weight changes'
    ],

    'Pediatric Complaints' => [
      'Poor feeding',
      'Crying excessively',
      'Fever in child',
      'Failure to thrive',
      'Delayed milestones',
      'Vomiting in child',
      'Diarrhea in child'
    ],

    'Injury & Emergency (OPD Triage)' => [
      'Minor trauma',
      'Cuts and wounds',
      'Burns',
      'Animal bites',
      'Road traffic injuries (minor)',
      'Assault-related injuries'
    ],

    'Follow-up / Administrative' => [
      'Review visit',
      'Medication refill',
      'Lab results review',
      'Referral follow-up',
      'Medical certificate',
      'Chronic disease follow-up'
    ]
  }
end


  def create_set_concept(name)
    find_or_create_concept(name, set: true)
  end

  def create_concept(name, set: false)
    find_or_create_concept(name, set: set)
  end

  def find_or_create_concept(name, set:)
    existing_name = ConceptName
                      .where(name: name, locale: LOCALE)
                      .order(locale_preferred: :desc)
                      .first

    return existing_name.concept if existing_name

    concept = Concept.create!(
      datatype_id: datatype(DATATYPE_NA).concept_datatype_id,
      class_id: concept_class(set ? SET_CLASS : CONCEPT_CLASS).concept_class_id,
      creator: @user_id,
      date_created: @now,
      is_set: set
    )

    ConceptName.create!(
      concept: concept,
      name: name,
      locale: LOCALE,
      locale_preferred: 1,
      creator: @user_id,
      date_created: @now,
      concept_name_type: FULLY_SPECIFIED
    )

    concept
  end

 def link_set(parent, child)
  sql = <<~SQL
    INSERT INTO concept_set (
      concept_set,
      concept_id,
      creator,
      date_created,
      uuid
    )
    SELECT
      #{parent.id},
      #{child.id},
      #{@user_id},
      '#{@now.to_s(:db)}',
      '#{SecureRandom.uuid}'
    WHERE NOT EXISTS (
      SELECT 1
      FROM concept_set
      WHERE concept_set = #{parent.id}
        AND concept_id = #{child.id}
    )
  SQL

  ActiveRecord::Base.connection.execute(sql)
end



  def concept_class(name)
		puts "Finding concept class lookup for #{name}"
    ConceptClass.find_by!(name: name)
  end

  def datatype(name)
    ConceptDatatype.find_by!(name: name)
  end
end

# Usage:
PresentingComplaintConceptExporter.new(user_id: 1).run
