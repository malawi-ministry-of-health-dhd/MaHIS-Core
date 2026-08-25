# frozen_string_literal: true

# Puma can serve each request in a thread from an internal thread pool.
# The `threads` method setting takes two numbers: a minimum and maximum.
# Any libraries that use thread pools should be configured to match
# the maximum value specified for Puma. Default is set to 5 threads for minimum
# and maximum; this matches the default thread size of Active Record.
#
max_threads = ENV.fetch('RAILS_MAX_THREADS', 5)
min_threads = ENV.fetch('RAILS_MIN_THREADS', [max_threads.to_i, 1].min)
threads min_threads, max_threads

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
#
port        ENV.fetch('PORT', 3000)

# Specifies the `environment` that Puma will run in.
#
environment ENV.fetch('RAILS_ENV', 'development')

# Specifies the number of `workers` to boot in clustered mode.
# Workers are forked webserver processes. If using threads and workers together
# the concurrency of the application would be max `threads` * `workers`.
# Workers do not work on JRuby or Windows (both of which do not support
# processes).
#
# On this machine, Puma's forked cluster workers are pathologically slow for
# any syscall-heavy work (mysql2 network reads, even plain file opens) -
# traced to Sophos Endpoint's Network Extension/Endpoint Security scan
# extension re-vetting every syscall from freshly forked child processes.
# A single long-lived process (the plain, unforked Puma master) is already
# trusted and unaffected: the VL-due report goes from ~175s (4 workers) to
# ~18s (0 workers) with identical code/queries. This is a local dev-machine
# artifact (confirmed via `sample` profiling + `systemextensionsctl list`)
# and is not expected to reproduce on production Linux hosts, so only
# default development to single-process mode; production keeps clustering.
default_workers = ENV.fetch('RAILS_ENV', 'development') == 'development' ? 0 : 4
workers ENV.fetch('WEB_CONCURRENCY', default_workers)

# Use the `preload_app!` method when specifying a `workers` number.
# This directive tells Puma to first boot the application and load code
# before forking the application. This takes advantage of Copy On Write
# process behavior so workers use less memory.
#
preload_app!

# Reconnect ActiveRecord/mysql2 after fork - standard practice for clustered
# Puma so forked workers don't share the parent's live DB socket.
before_fork do
  ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
end

on_worker_boot do
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord::Base)
end

# Allow puma to be restarted by `rails restart` command.
plugin :tmp_restart
