namespace :sync do
  desc "Run all sync jobs in parallel"
  task all: :environment do
    # Fail fast if CouchDB is unreachable, otherwise the index check below (and
    # every sync job) hangs on RestClient's ~60s-per-request connect with no
    # useful message. A short pre-flight turns a freeze into a clear error.
    require 'rest-client'
    begin
      RestClient::Request.execute(
        method: :get,
        url: CouchdbPatientService.couchdb_url('_up'),
        timeout: 5, open_timeout: 5
      )
    rescue StandardError => e
      puts "❌ CouchDB is unreachable (#{e.class}: #{e.message})."
      puts '   Sync aborted — start CouchDB or check the network/VPN, then re-run `rails sync:all`.'
      puts '   Diagnose with: rails sync:doctor'
      next
    end

    puts 'Checking CouchDB reference-data indexes...'
    if CouchdbIndexMaintenance.ensure_reference_data!(logger: Rails.logger)
      puts '✅ CouchDB reference-data indexes verified.'
    else
      puts '⚠️  Could not verify every CouchDB reference-data index. Check Rails logs for details.'
    end
    puts 'Patient record indexes will be verified after patient sync drains.'

    jobs = [
      Sync::BatchPatientSyncJob,
      Sync::FacilitySyncJob,
      Sync::SpecimenSyncJob,
      Sync::VisitSyncJob,
      Sync::StageSyncJob,
      Sync::StockSyncJob,
      Sync::TestResultIndicatorsSyncJob,
      Sync::TestTypesSyncJob,
      Sync::ConceptNameSyncJob,
      Sync::ConceptSetSyncJob,
      Sync::DistrictSyncJob,
      Sync::DrugSyncJob,
      Sync::ProgramSyncJob,
      Sync::RelationshipTypeSyncJob,
      Sync::TraditionalAuthoritySyncJob,
      Sync::VillageSyncJob,
      Sync::DdeIdsSyncJob,
      Sync::LabAccessionNumberSyncJob,
      Sync::DiagnosisSyncJob,
      Sync::WardSyncJob,
      Sync::SectionSyncJob,
      Sync::RolesPermissionsSyncJob,
      Sync::RegimenIngredientSyncJob,
      Sync::DepartmentSyncJob,
      Sync::SectionSyncJob,
      Sync::CustomRegimenIngredientSyncJob,
      Sync::GlobalPropertySyncJob,
      Sync::UserPropertySyncJob,
      Sync::MnhStatsSyncJob,
      Sync::RegimenExtraSyncJob,
      Sync::RegimenStarterPackSyncJob,
      Sync::ArvDrugSyncJob,
      Sync::BedSyncJob,
      Sync::ImpowDrugSyncJob
    ]

    # Fresh run: clear any stale progress so the bars start from zero.
    SyncProgress.reset_all!

    jobs.each(&:perform_async)
    puts "✅ Enqueued #{jobs.size} sync jobs in parallel."

    # WATCH=0 (or NO_WATCH=1) just enqueues without the live dashboard.
    if ENV['WATCH'] == '0' || ENV['NO_WATCH'] == '1'
      puts 'Run `rails sync:progress` to watch progress.'
    else
      puts 'Watching progress (Ctrl-C to stop watching; sync keeps running)...'
      sleep 1 # give the first jobs a moment to register their totals
      SyncDashboard.new.watch
    end
  end

  desc 'Watch live progress of an in-flight sync (tables + index builds)'
  task progress: :environment do
    if SyncProgress.snapshot.empty?
      puts 'No active sync found. Start one with `rails sync:all`.'
    else
      SyncDashboard.new.watch
    end
  end

  desc "Run a specific sync job by name. Example: rails sync:run[StageSyncJob]"
  task :run, [:job_name] => :environment do |t, args|
    if args[:job_name].blank?
      puts "⚠️  Please provide a job name. Example: rails sync:run[StageSyncJob]"
      next
    end

    begin
      job_class = "Sync::#{args[:job_name]}".constantize
      job_class.perform_async
      puts "✅ Enqueued #{job_class}"
    rescue NameError
      puts "❌ Job Sync::#{args[:job_name]} not found."
    end
  end

  desc 'Diagnose why a CouchDB sync is not progressing (Sidekiq, queues, CouchDB, locks)'
  task doctor: :environment do
    require 'sidekiq/api'
    require 'rest-client'
    require 'json'
    line = '-' * 64

    # Sidekiq 8 yields a redis-client connection (no #scan_each); use raw SCAN.
    redis_scan = lambda do |pattern|
      Sidekiq.redis do |conn|
        cursor = '0'
        found = []
        loop do
          cursor, batch = conn.call('SCAN', cursor, 'MATCH', pattern, 'COUNT', 1000)
          found.concat(batch)
          break if cursor == '0'
        end
        found
      end
    end

    puts 'CouchDB sync doctor'
    puts line

    # Confirm the running code has the updated dashboard (helps spot stale deploys).
    updated = SyncDashboard.private_instance_methods.include?(:stalled?)
    puts "Dashboard code: #{updated ? 'updated' : 'OLD — pull latest lib/sync_dashboard.rb'}"
    puts line

    processes = Sidekiq::ProcessSet.new
    puts "Sidekiq processes running: #{processes.size}"
    puts '  >> No worker running. Start:  bundle exec sidekiq -C config/sidekiq.yml' if processes.size.zero?
    processes.each do |p|
      puts "  pid=#{p['pid']} host=#{p['hostname']} queues=[#{Array(p['queues']).join(',')}] concurrency=#{p['concurrency']} busy=#{p['busy']}"
    end
    puts line

    puts 'Queue depths:'
    %w[batch_sync patient_sync sync_offline_data default].each do |q|
      puts "  #{q.ljust(20)} #{Sidekiq::Queue.new(q).size}"
    end
    puts "  scheduled=#{Sidekiq::ScheduledSet.new.size} retry=#{Sidekiq::RetrySet.new.size} dead=#{Sidekiq::DeadSet.new.size}"
    Sidekiq::RetrySet.new.first(5).each { |j| puts "  RETRY #{j.klass} (#{j.queue}): #{j['error_message']}" }
    Sidekiq::DeadSet.new.first(5).each  { |j| puts "  DEAD  #{j.klass} (#{j.queue}): #{j['error_message']}" }
    puts line

    workers = Sidekiq::Workers.new.to_a
    puts "Busy workers: #{workers.size}"
    workers.each do |_pid, _tid, work|
      queue   = work.respond_to?(:queue) ? work.queue : work['queue']
      payload = work.respond_to?(:payload) ? work.payload : work['payload']
      payload = JSON.parse(payload) if payload.is_a?(String)
      run_at  = work.respond_to?(:run_at) ? work.run_at : work['run_at']
      ran     = run_at ? (Time.now.to_i - run_at.to_i) : '?'
      puts "  #{queue} #{payload && payload['class']} running #{ran}s"
    end
    puts line

    snap = SyncProgress.snapshot
    puts "SyncProgress datasets: #{snap.size}"
    snap.each { |r| puts "  #{r[:type].to_s.ljust(28)} #{r[:done]}/#{r[:total]} #{r[:status]}" }
    puts line

    begin
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      RestClient::Request.execute(method: :get, url: CouchdbPatientService.couchdb_url('_up'), timeout: 5, open_timeout: 5)
      puts "CouchDB reachable in #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)}s"
    rescue StandardError => e
      puts "CouchDB UNREACHABLE: #{e.class}: #{e.message}"
      puts '  >> The patient job calls CouchDB before registering progress and can hang here (RestClient has no timeout).'
    end
    puts line

    # DB connection pool vs Sidekiq concurrency. Read from the same config the
    # worker uses; if the pool is smaller than concurrency (20), worker threads
    # block waiting for a connection — the usual cause of "all workers busy, no
    # progress". (Restart Sidekiq after changing the pool for it to take effect.)
    pool_size = ActiveRecord::Base.connection_pool.size
    puts "DB pool size: #{pool_size} (RAILS_MAX_THREADS=#{ENV['RAILS_MAX_THREADS'] || 'unset'}); Sidekiq concurrency=20"
    puts '  >> Pool < 20: raise it (config/database.yml) and restart Sidekiq.' if pool_size < 20
    puts line

    # MySQL processlist is server-side, so it shows ALL app connections including
    # the 20 worker threads. This distinguishes a DB-side lock/slow query (many
    # rows with high time/state) from Ruby-side connection starvation (few rows).
    puts 'MySQL processlist (longest-running non-idle first):'
    begin
      result = ActiveRecord::Base.connection.exec_query(<<~SQL.squish)
        SELECT id, command, time, state, LEFT(COALESCE(info, ''), 90) AS info
        FROM information_schema.processlist
        WHERE command <> 'Sleep'
        ORDER BY time DESC
        LIMIT 20
      SQL
      active = result.to_a
      puts "  active (non-sleep) connections: #{active.size}"
      active.each do |r|
        puts "  id=#{r['id']} time=#{r['time']}s cmd=#{r['command']} state=#{r['state'].to_s[0, 30]} :: #{r['info']}"
      end
      if active.size <= 1
        puts '  >> Almost nothing is active in MySQL while workers are "busy" → they are blocked in'
        puts '     Ruby, most likely waiting for a DB connection. Check the DB pool size above.'
      end
    rescue StandardError => e
      puts "  processlist error: #{e.message}"
    end
    puts line

    begin
      keys = redis_scan.call('uniquejobs:*')
      puts "sidekiq-unique-jobs lock keys: #{keys.size}"
      if keys.size.positive? && Sidekiq::Queue.new('sync_offline_data').size.zero? && processes.size.positive?
        puts '  >> Locks present but queues empty: a previous run likely left stale locks that are'
        puts '     silently dropping re-enqueued jobs. Clear them:  rails sync:clear_locks'
      end
    rescue StandardError => e
      puts "lock check error: #{e.message}"
    end
    puts line
  end

  desc 'Clear stale sidekiq-unique-jobs locks (use if sync:all enqueues nothing)'
  task clear_locks: :environment do
    deleted = Sidekiq.redis do |conn|
      cursor = '0'
      keys = []
      loop do
        cursor, batch = conn.call('SCAN', cursor, 'MATCH', 'uniquejobs:*', 'COUNT', 1000)
        keys.concat(batch)
        break if cursor == '0'
      end
      keys.each_slice(1000) { |slice| conn.call('DEL', *slice) } unless keys.empty?
      keys.size
    end
    puts "Cleared #{deleted} unique-job lock entries. Re-run: rails sync:all"
  end
end


# sync all records with couchDB
# rails sync:all

# Run only one job (e.g. StageSyncJob)
# rails "sync:run[StageSyncJob]"
