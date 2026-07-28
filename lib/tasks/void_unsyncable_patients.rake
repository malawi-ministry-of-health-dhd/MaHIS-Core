# frozen_string_literal: true

namespace :patients do
  desc 'Dry-run or void patients without a valid type-3 identifier or any program enrollment'
  task void_unsyncable: :environment do
    VoidUnsyncablePatientsTask.new.run
  end
end
