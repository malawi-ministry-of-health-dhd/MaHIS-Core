# frozen_string_literal: true

# Redis-backed progress store shared across Sidekiq workers and the sync rake
# tasks. Each logical dataset ("type", e.g. a model/db name) gets a small hash
# with total/done/status, plus a registry set listing every tracked type.
#
# All methods are best-effort and never raise: progress reporting must never
# break an actual sync. If Redis is unavailable, calls quietly no-op.
module SyncProgress
  REGISTRY_KEY = 'sync:progress:index'
  TYPE_KEY_PREFIX = 'sync:progress:t:'
  TTL_SECONDS = 24 * 60 * 60 # entries self-expire after a day

  module_function

  # Register a dataset and reset its counters to a fresh "running" state.
  def start(type, total)
    type = normalize(type)
    return if type.blank?

    with_redis do |redis|
      redis.sadd(REGISTRY_KEY, type)
      redis.expire(REGISTRY_KEY, TTL_SECONDS)
      key = type_key(type)
      redis.hset(key,
                 'type', type,
                 'total', total.to_i,
                 'done', 0,
                 'status', 'running',
                 'started_at', now,
                 'updated_at', now)
      redis.expire(key, TTL_SECONDS)
    end
  end

  # Set the absolute completed count. Safe when a single process owns the type
  # (the standard per-job batch loops). Avoids double-count under retries.
  def set(type, done)
    type = normalize(type)
    return if type.blank?

    with_redis do |redis|
      key = type_key(type)
      redis.hset(key, 'done', done.to_i, 'updated_at', now)
      redis.expire(key, TTL_SECONDS)
    end
  end

  # Atomically add to the completed count. Use when many workers contribute to
  # one type (the patient bulk fan-out).
  def increment(type, by = 1)
    type = normalize(type)
    return if type.blank?

    with_redis do |redis|
      key = type_key(type)
      redis.hincrby(key, 'done', by.to_i)
      redis.hset(key, 'updated_at', now)
      redis.expire(key, TTL_SECONDS)
    end
  end

  # Ensure a type is registered with a known total without resetting progress.
  # Used by coordinators (e.g. patient fan-out) that know the total up front.
  def ensure(type, total)
    type = normalize(type)
    return if type.blank?

    with_redis do |redis|
      redis.sadd(REGISTRY_KEY, type)
      redis.expire(REGISTRY_KEY, TTL_SECONDS)
      key = type_key(type)
      if redis.exists(key).to_i.zero?
        redis.hset(key,
                   'type', type,
                   'total', total.to_i,
                   'done', 0,
                   'status', 'running',
                   'started_at', now,
                   'updated_at', now)
      end
      redis.hset(key, 'total', total.to_i) if total.to_i.positive?
      redis.expire(key, TTL_SECONDS)
    end
  end

  def finish(type)
    update_status(type, 'done')
  end

  def fail(type, message = nil)
    update_status(type, 'failed', message)
  end

  # Wipe all tracked progress (called at the start of a fresh sync:all run).
  def reset_all!
    with_redis do |redis|
      types = redis.smembers(REGISTRY_KEY)
      keys = types.map { |t| type_key(t) }
      redis.del(*keys) unless keys.empty?
      redis.del(REGISTRY_KEY)
    end
  end

  # Array of hashes describing every tracked type, for rendering.
  def snapshot
    with_redis do |redis|
      types = redis.smembers(REGISTRY_KEY).sort
      types.filter_map do |type|
        data = redis.hgetall(type_key(type))
        next if data.empty?

        {
          type: data['type'] || type,
          total: data['total'].to_i,
          done: data['done'].to_i,
          status: data['status'] || 'running',
          message: data['message'],
          started_at: data['started_at'],
          updated_at: data['updated_at']
        }
      end
    end || []
  end

  def all_finished?
    snap = snapshot
    return false if snap.empty?

    snap.all? { |row| %w[done failed].include?(row[:status]) }
  end

  # --- internal helpers -----------------------------------------------------

  def update_status(type, status, message = nil)
    type = normalize(type)
    return if type.blank?

    with_redis do |redis|
      key = type_key(type)
      redis.hset(key, 'status', status, 'updated_at', now)
      redis.hset(key, 'message', message.to_s) if message
      # On success, snap the bar to 100% so a final partial batch still reads full.
      if status == 'done'
        total = redis.hget(key, 'total').to_i
        redis.hset(key, 'done', total) if total.positive?
      end
      redis.expire(key, TTL_SECONDS)
    end
  end

  def type_key(type)
    "#{TYPE_KEY_PREFIX}#{type}"
  end

  def normalize(type)
    type.to_s.strip
  end

  def now
    Time.now.utc.iso8601
  end

  # Reuse Sidekiq's Redis pool when present; otherwise fall back to a plain
  # Redis client so the rake task can read progress even outside a worker.
  def with_redis
    if defined?(Sidekiq)
      Sidekiq.redis { |conn| yield conn }
    else
      yield fallback_redis
    end
  rescue StandardError => e
    warn("SyncProgress error: #{e.class}: #{e.message}") if $DEBUG
    nil
  end

  def fallback_redis
    @fallback_redis ||= Redis.new
  end
end
