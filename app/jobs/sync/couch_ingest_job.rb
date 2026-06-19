# app/jobs/sync/couch_ingest_job.rb
require Rails.root.join('lib', 'couchdb_changes_listener').to_s

module Sync
  # Fan-out worker for the CouchDB -> MySQL/TiDB ingest path. The listener, when
  # running in fan_out mode, enqueues one of these per changed/unprocessed document
  # instead of processing inline. The job re-uses the listener's processing logic
  # (fetch latest doc, run the processor, mark processed, retry/dead-letter on
  # failure) so behaviour and the processed_by_listener recovery flag are identical
  # to the inline path — only the concurrency model differs.
  #
  # Bounded concurrency is achieved by running this queue on its own Sidekiq
  # process with a small -c (see config/sidekiq.yml notes), which keeps TiDB write
  # contention in check. Duplicate enqueues for the same document are deduped by
  # the global sidekiq-unique-jobs lock (keyed on the job args).
  class CouchIngestJob
    include Sidekiq::Job
    sidekiq_options queue: :couch_ingest, retry: 3

    def perform(db_name, doc_id)
      CouchdbChangesListener.build(db_name).ingest_document(doc_id)
    end
  end
end
