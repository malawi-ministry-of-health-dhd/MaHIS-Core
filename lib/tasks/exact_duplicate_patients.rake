# frozen_string_literal: true

namespace :patients do
  desc 'Export exact duplicates, merge reviewed rows, or process all with explicit unattended confirmation'
  task cleanup_exact_duplicates: :environment do
    ExactDuplicatePatientCleanupTask.new.run
  end
end
 