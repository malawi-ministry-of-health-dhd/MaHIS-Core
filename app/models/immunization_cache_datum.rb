class ImmunizationCacheDatum < ApplicationRecord
  def self.upsert_cache(name:, location_id:, value:)
    now = Time.now
    upsert({ name:, location_id:, value:, created_at: now, updated_at: now })
  end
end
