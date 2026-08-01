# frozen_string_literal: true

namespace :couchdb do
  desc 'Disable continuous CouchDB compaction; the nightly Sidekiq job becomes the only scheduler'
  task disable_automatic_compaction: :environment do
    abort('CouchDB is not configured or could not be updated') unless CouchdbCompactionService.disable_automatic_compaction!
  end

  desc 'Run the same sequential CouchDB compaction used by the nightly Sidekiq job'
  task compact_now: :environment do
    abort('CouchDB is not configured') unless CouchdbCompactionService.run!
  end
end
