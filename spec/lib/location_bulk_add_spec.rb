# frozen_string_literal: true

require 'rails_helper'
require 'tempfile'
require 'open3'

RSpec.describe 'location_bulk_add apply preflight handling' do
  let(:tag_name) { 'Village Clinic' }
  let(:parent_name) { 'Parent Health Centre' }

  before do
    LocationTag.unscoped.find_or_create_by!(name: tag_name) do |tag|
      tag.creator = 1
      tag.date_created = Time.current
      tag.uuid = SecureRandom.uuid
    end

    Location.unscoped.find_or_create_by!(name: parent_name) do |location|
      location.creator = 1
      location.date_created = Time.current
      location.uuid = SecureRandom.uuid
      location.retired = false
    end
  end

  it 'logs missing parent rows without aborting the import' do
    csv = Tempfile.new(['location_bulk_add', '.csv'])
    csv.write("name,parent_facility,clinic,district\n")
    csv.write("Valid Clinic,#{parent_name},true,District A\n")
    csv.write("Missing Clinic,No Such Parent,true,District A\n")
    csv.close

    stdout, stderr, status = Open3.capture3(
      'bundle', 'exec', 'ruby', 'bin/location_bulk_add.rb', 'apply', '--input', csv.path, '--dry-run',
      chdir: Rails.root.to_s
    )

    expect(status.exitstatus).to eq(0), "stdout=#{stdout}\nstderr=#{stderr}"
    expect(stdout).to include('Created: 1')
    expect(stdout).to include('ERROR line=3')
    expect(stdout).not_to include('Apply aborted: preflight checks failed')
  ensure
    csv&.unlink
  end
end
