# frozen_string_literal: true

namespace :identifiers do
  desc 'Export duplicate identifiers, apply reviewed repairs, or process supported repairs unattended'
  task cleanup_duplicates: :environment do
    DuplicateIdentifierCleanupTask.new.run
  end
end
