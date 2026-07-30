# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sync::ImpowDrugSyncJob, type: :job do
  subject(:job) { described_class.new }

  describe '#build_reference_document' do
    it 'builds all program sections through Ruby method calls' do
      allow(job).to receive_messages(
        sfs_program_section: { 'program_code' => 'SFS' },
        ots_program_section: { 'program_code' => 'OTS' },
        its_program_section: { 'program_code' => 'ITS' },
        couchdb_views: {}
      )

      document = job.send(:build_reference_document)

      expect(document.fetch('programs')).to eq(
        'sfs' => { 'program_code' => 'SFS' },
        'ots' => { 'program_code' => 'OTS' },
        'its' => { 'program_code' => 'ITS' }
      )
    end
  end
end
