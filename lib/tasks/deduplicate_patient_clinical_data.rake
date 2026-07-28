# frozen_string_literal: true

require 'csv'
require 'fileutils'

namespace :clinical_data do
  desc 'Dry-run, apply, or enqueue duplicate observation/order cleanup for selected patients'
  task deduplicate: :environment do
    cleanup = DeduplicatePatientClinicalDataTask.new
    ENV['ASYNC'].to_s == '1' ? cleanup.enqueue : cleanup.run
  end

  desc 'Export OPD patients with repeated semantic observations to CSV'
  task opd_duplicate_report: :environment do
    minimum_duplicates = [ENV.fetch('MIN_DUPLICATES', '1').to_i, 1].max
    output_path = ENV['OUTPUT'].presence ||
                  Rails.root.join('tmp', 'opd_duplicate_patient_ids.csv').to_s
    output_path = File.expand_path(output_path, Rails.root)
    FileUtils.mkdir_p(File.dirname(output_path))

    rows = ActiveRecord::Base.connection.select_all(<<~SQL).to_a
      SELECT person_id,
             SUM(group_count - 1) AS duplicate_observations,
             SUM(group_count) AS rows_in_duplicate_groups,
             MAX(group_count) AS largest_repeat,
             MIN(first_created) AS first_duplicate_group_created,
             MAX(last_created) AS last_duplicate_group_created
      FROM (
        SELECT o.person_id, o.encounter_id, o.concept_id, o.location_id,
               o.accession_number, o.comments, o.value_boolean, o.value_coded,
               o.value_coded_name_id, o.value_complex, o.value_datetime,
               o.value_drug, o.value_group_id, o.value_modifier, o.value_numeric,
               o.value_text, COUNT(*) AS group_count,
               MIN(o.date_created) AS first_created,
               MAX(o.date_created) AS last_created
        FROM obs o
        INNER JOIN encounter e ON e.encounter_id = o.encounter_id
        WHERE e.program_id = 14 AND e.voided = 0 AND o.voided = 0
        GROUP BY o.person_id, o.encounter_id, o.concept_id, o.location_id,
                 o.accession_number, o.comments, o.value_boolean, o.value_coded,
                 o.value_coded_name_id, o.value_complex, o.value_datetime,
                 o.value_drug, o.value_group_id, o.value_modifier, o.value_numeric,
                 o.value_text
        HAVING COUNT(*) > 1
      ) duplicate_groups
      GROUP BY person_id
      HAVING SUM(group_count - 1) >= #{minimum_duplicates}
      ORDER BY duplicate_observations DESC, person_id
    SQL

    CSV.open(output_path, 'w', write_headers: true, headers: %w[
      patient_id duplicate_observations rows_in_duplicate_groups largest_repeat
      first_duplicate_group_created last_duplicate_group_created severity
    ]) do |csv|
      rows.each do |row|
        duplicate_count = row['duplicate_observations'].to_i
        severity =
          if duplicate_count >= 1_000
            'critical'
          elsif duplicate_count >= 100
            'high'
          elsif duplicate_count >= 10
            'medium'
          else
            'low'
          end

        csv << [
          row['person_id'],
          duplicate_count,
          row['rows_in_duplicate_groups'],
          row['largest_repeat'],
          row['first_duplicate_group_created'],
          row['last_duplicate_group_created'],
          severity
        ]
      end
    end

    puts "Exported #{rows.length} OPD patient(s) to #{output_path}"
  end
end
