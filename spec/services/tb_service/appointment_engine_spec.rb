# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TbService::AppointmentEngine do
  subject { TbService::AppointmentEngine }
  let(:patient) { create :patient }
  let(:program) { Program.find_by_name('TB Program') || create(:program, name: 'TB Program') }
  let(:epoch) { Date.today }

  before(:each) do
    Program.find_or_create_by!(name: 'TB Program') do |program|
      program.description = 'TB Program'
      program.creator = 1
      program.date_created = Time.now
      program.retired = 0
      program.uuid = SecureRandom.uuid
    end

    EncounterType.find_or_create_by!(name: 'TREATMENT')
    EncounterType.find_or_create_by!(name: 'APPOINTMENT')

    tb_drugs_concept = ConceptName.find_by(name: 'TUBERCULOSIS DRUGS')&.concept ||
                       Concept.create!(datatype_id: 4, class_id: 10, is_set: 0,
                                       creator: 1, date_created: Time.now, retired: 0,
                                       uuid: SecureRandom.uuid).tap do |concept|
                         ConceptName.create!(concept:, name: 'TUBERCULOSIS DRUGS',
                                             locale: 'en', creator: 1,
                                             date_created: Time.now, voided: 0,
                                             uuid: SecureRandom.uuid)
                       end

    next if Drug.where(concept_id: ConceptSet.where(concept_set: tb_drugs_concept).select(:concept_id)).exists?

    tb_drug_concept = Concept.create!(datatype_id: 4, class_id: 10, is_set: 0,
                                      creator: 1, date_created: Time.now, retired: 0,
                                      uuid: SecureRandom.uuid).tap do |concept|
                        ConceptName.create!(concept:, name: 'Rifabutin (300mg)',
                                            locale: 'en', creator: 1,
                                            date_created: Time.now, voided: 0,
                                            uuid: SecureRandom.uuid)
                      end

    ConceptSet.create!(set: tb_drugs_concept, concept: tb_drug_concept,
                       creator: 1, date_created: Time.now, uuid: SecureRandom.uuid)

    Drug.create!(concept: tb_drug_concept, name: 'Rifabutin (300mg)',
                 form: Concept.first || Concept.create!(datatype_id: 4, class_id: 10, is_set: 0,
                                                        creator: 1, date_created: Time.now, retired: 0,
                                                        uuid: SecureRandom.uuid),
                 date_created: Time.now, creator: 1, retired: 0,
                 uuid: SecureRandom.uuid)
  end

  describe :next_appointment do
    it 'does not suggest appointments on clinic days' do
      epoch = Date.strptime '2018-10-23' # Was a tuesday...

      treatment_encounter = create(:encounter_treatment, patient:,
                                                         encounter_datetime: epoch,
                                                         program:)
      drug = Drug.tb_drugs[0]

      order = create :order, auto_expire_date: epoch,
                             start_date: epoch,
                             patient:,
                             concept: drug.concept,
                             encounter: treatment_encounter

      create(:drug_order, order:, drug:)

      # Expecting a 4 day backward shift as the conventional 2 lands on
      # a sunday which is a default non-clinic day. Saturday too is skipped
      # as it is another non-clinic day.
      expected_date = (epoch - 4.days).to_date

      engine = subject.new program:, patient:, retro_date: epoch
      date = engine.next_appointment_date[:appointment_date]
      expect(date).to eq(expected_date)
    end

    it 'adjusts shortest expiry date back by 2 days' do
      epoch = Date.strptime '2018-10-26' # Was a friday...

      treatment_encounter = create(:encounter_treatment, patient:,
                                                         encounter_datetime: epoch,
                                                         program:)
      drug = Drug.tb_drugs[0]

      order = create :order, auto_expire_date: epoch,
                             start_date: epoch,
                             patient:,
                             concept: drug.concept,
                             encounter: treatment_encounter

      create(:drug_order, order:, drug:)

      expected_date = (epoch - 2.days).to_date

      engine = subject.new program:, patient:, retro_date: epoch
      date = engine.next_appointment_date[:appointment_date]
      expect(date).to eq(expected_date)
    end

    it 'selects shortest expiry date among available drug orders' do
      epoch = Date.strptime '2018-10-24' # Was a wednesday...

      treatment_encounter = create(:encounter_treatment, patient:,
                                                         encounter_datetime: epoch,
                                                         program:)
      tb_drugs = Drug.tb_drugs

      (0...5).collect do |i|
        drug = tb_drugs[i]
        order = create :order, auto_expire_date: epoch + i.days,
                               start_date: epoch,
                               patient:,
                               concept: drug.concept,
                               encounter: treatment_encounter

        create :drug_order, order:, drug:
      end

      # Expecting a 2 day backward shift from our epoch must be our shortest
      # expiry date
      expected_date = (epoch - 2.days).to_date

      engine = subject.new program:, patient:, retro_date: epoch
      date = engine.next_appointment_date[:appointment_date]
      expect(date).to eq(expected_date)
    end
  end
end
