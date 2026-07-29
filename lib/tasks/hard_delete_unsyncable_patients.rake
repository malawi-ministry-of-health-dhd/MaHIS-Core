# frozen_string_literal: true

namespace :patients do
  desc 'Dry-run or permanently delete complete records for unsyncable, unenrolled patients'
  task hard_delete_unsyncable: :environment do
    HardDeleteUnsyncablePatientsTask.new.run
  end
end
