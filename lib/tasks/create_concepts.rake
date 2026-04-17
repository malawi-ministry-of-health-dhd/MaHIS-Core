# frozen_string_literal: true

namespace :concepts do
  desc 'Load custom application concepts'
  task create_concepts: :environment do
    loader = CreateConcepts::ConceptLoader.new
    loader.load!
  end
end

module CreateConcepts
  class ConceptLoader
    CONCEPTS = [
      { name: 'Patient admission outcome', datatype: 'Text', class: 'Misc' },
      { name: 'Insecticide treated net given', datatype: 'Coded', class: 'Misc' },
      { name: 'Reason ITN not provided', datatype: 'Text', class: 'Misc' },
      { name: 'Admit to high risk', datatype: 'Coded', class: 'Procedure' },

      # ANC profile concepts
      { name: 'Behaviour finding', datatype: 'N/A', class: 'Misc' },
      { name: 'Current pregnancy finding', datatype: 'N/A', class: 'Misc' },
      { name: 'Date of ANC visit 1', datatype: 'N/A', class: 'Misc' },
      { name: 'Date of ANC visit 2', datatype: 'N/A', class: 'Misc' },
      { name: 'Date of ANC visit 3', datatype: 'N/A', class: 'Misc' },
      { name: 'Date of ANC visit 4', datatype: 'N/A', class: 'Misc' },
      { name: 'Date of ANC visit 5', datatype: 'N/A', class: 'Misc' },
      { name: 'Date of ANC visit 6', datatype: 'N/A', class: 'Misc' },
      { name: 'Date of ANC visit 7', datatype: 'N/A', class: 'Misc' },
      { name: 'Facility from which the client received ANC care 1', datatype: 'N/A', class: 'Misc' },
      { name: 'Facility from which the client received ANC care 2', datatype: 'N/A', class: 'Misc' },
      { name: 'Facility from which the client received ANC care 3', datatype: 'N/A', class: 'Misc' },
      { name: 'Facility from which the client received ANC care 4', datatype: 'N/A', class: 'Misc' },
      { name: 'Facility from which the client received ANC care 5', datatype: 'N/A', class: 'Misc' },
      { name: 'Facility from which the client received ANC care 6', datatype: 'N/A', class: 'Misc' },
      { name: 'Facility from which the client received ANC care 7', datatype: 'N/A', class: 'Misc' },
      { name: 'Medical history finding', datatype: 'N/A', class: 'Misc' },
      { name: 'Medication finding', datatype: 'N/A', class: 'Misc' },
      { name: 'Mode of delivery details', datatype: 'N/A', class: 'Misc' },
      { name: 'Not treated', datatype: 'N/A', class: 'Misc' },
      { name: 'Other Gynaecological information', datatype: 'N/A', class: 'Misc' },
      { name: 'Past obstetric finding', datatype: 'N/A', class: 'Misc' },
      { name: 'STIs', datatype: 'N/A', class: 'Misc' },
      { name: 'Fetus number', datatype: 'N/A', class: 'Misc' },
      { name: 'Treated', datatype: 'N/A', class: 'Misc' },
      { name: 'Blood loss ≥300ml + one abnormal observation', datatype: 'N/A', class: 'Misc' },
      { name: 'Blood loss ≥500ml', datatype: 'N/A', class: 'Misc' },
    ].freeze

    def load!
      ActiveRecord::Base.transaction do
        CONCEPTS.each do |concept_data|
          find_or_create_concept!(concept_data)
        end
      end
      puts "Successfully loaded #{CONCEPTS.size} custom concepts"
    end

    private

    def find_or_create_concept!(concept_data)
      concept_name = concept_data[:name]

      existing_concept = Concept.joins(:concept_names)
                                .where(concept_name: { name: concept_name })
                                .first

      if existing_concept
        puts "Concept '#{concept_name}' already exists (concept_id: #{existing_concept.concept_id})"
        return existing_concept
      end

      datatype = ConceptDatatype.find_by(name: concept_data[:datatype])
      klass = ConceptClass.find_by(name: concept_data[:class])

      unless datatype && klass
        raise "Missing concept datatype (#{concept_data[:datatype]}) or concept class (#{concept_data[:class]})"
      end

      concept = Concept.create!(
        datatype_id: datatype.concept_datatype_id,
        class_id: klass.concept_class_id,
        creator: creator_id,
        date_created: Time.now,
        retired: 0,
        is_set: 0
      )

      ConceptName.create!(
        concept_id: concept.concept_id,
        name: concept_name,
        locale: 'en',
        concept_name_type: 'FULLY_SPECIFIED',
        creator: creator_id,
        date_created: Time.now
      )

      # Add numeric type metadata if applicable
      if concept_data[:datatype] == 'Numeric' && concept_data[:units]
        add_numeric_metadata(concept, concept_data[:units])
      end

      puts "Created concept '#{concept_name}' (concept_id: #{concept.concept_id})"
      concept
    end

    def add_numeric_metadata(concept, units)
      # Try to create concept numeric metadata
      begin
        ConceptNumeric.create!(
          concept_id: concept.concept_id,
          hi_absolute: nil,
          hi_critical: nil,
          hi_normal: nil,
          low_absolute: nil,
          low_critical: nil,
          low_normal: nil,
          units: units,
          precise: 1
        )
      rescue StandardError => e
        puts "  Warning: Could not create numeric metadata: #{e.message}"
      end
    end

    def creator_id
      @creator_id ||= User.unscoped.order(:user_id).pick(:user_id) || 1
    end
  end
end
