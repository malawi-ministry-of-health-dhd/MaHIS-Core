# frozen_string_literal: true

require 'rails_helper'
require 'rake'

load Rails.root.join('lib/tasks/repair_obs_group_ids.rake')

RSpec.describe ObsGroupIdBatchResolution do
  def resolve(obs_batch:, source_group_by_uuid: {}, parent_uuid_by_source_id: {}, target_parent_id_by_uuid: {})
    described_class.new(
      obs_batch:,
      source_group_by_uuid:,
      parent_uuid_by_source_id:,
      target_parent_id_by_uuid:
    )
  end

  it 'resolves an observation whose source parent has already been migrated locally' do
    result = resolve(
      obs_batch: [[501, 'child-uuid']],
      source_group_by_uuid: { 'child-uuid' => 999 },
      parent_uuid_by_source_id: { 999 => 'parent-uuid' },
      target_parent_id_by_uuid: { 'parent-uuid' => 100 }
    )

    expect(result.resolved).to eq([[501, 100]])
    expect(result.skipped_not_in_source).to eq(0)
    expect(result.skipped_source_also_ungrouped).to eq(0)
    expect(result.skipped_parent_not_migrated).to eq(0)
  end

  it 'resolves multiple sibling observations that share the same migrated parent' do
    result = resolve(
      obs_batch: [[501, 'child-uuid-1'], [502, 'child-uuid-2']],
      source_group_by_uuid: { 'child-uuid-1' => 999, 'child-uuid-2' => 999 },
      parent_uuid_by_source_id: { 999 => 'parent-uuid' },
      target_parent_id_by_uuid: { 'parent-uuid' => 100 }
    )

    expect(result.resolved).to contain_exactly([501, 100], [502, 100])
  end

  it 'skips an observation whose uuid does not exist in the source database at all' do
    result = resolve(
      obs_batch: [[501, 'child-uuid']],
      source_group_by_uuid: {}
    )

    expect(result.resolved).to be_empty
    expect(result.skipped_not_in_source).to eq(1)
    expect(result.skipped_source_also_ungrouped).to eq(0)
    expect(result.skipped_parent_not_migrated).to eq(0)
  end

  it 'skips an observation whose source record is itself ungrouped' do
    result = resolve(
      obs_batch: [[501, 'child-uuid']],
      source_group_by_uuid: { 'child-uuid' => nil }
    )

    expect(result.resolved).to be_empty
    expect(result.skipped_source_also_ungrouped).to eq(1)
    expect(result.skipped_not_in_source).to eq(0)
    expect(result.skipped_parent_not_migrated).to eq(0)
  end

  it "skips an observation whose parent obs_id could not be found in the source database's own obs table" do
    result = resolve(
      obs_batch: [[501, 'child-uuid']],
      source_group_by_uuid: { 'child-uuid' => 999 },
      parent_uuid_by_source_id: {} # 999 not found remotely (e.g. deleted, or a data-quality outlier)
    )

    expect(result.resolved).to be_empty
    expect(result.skipped_parent_not_migrated).to eq(1)
  end

  it 'skips an observation whose parent uuid has not been migrated to the central database yet' do
    result = resolve(
      obs_batch: [[501, 'child-uuid']],
      source_group_by_uuid: { 'child-uuid' => 999 },
      parent_uuid_by_source_id: { 999 => 'parent-uuid' },
      target_parent_id_by_uuid: {} # parent-uuid not present locally
    )

    expect(result.resolved).to be_empty
    expect(result.skipped_parent_not_migrated).to eq(1)
  end

  it 'evaluates each observation in a batch independently and tallies every category at once' do
    result = resolve(
      obs_batch: [
        [1, 'resolvable'],
        [2, 'missing-from-source'],
        [3, 'ungrouped-in-source'],
        [4, 'parent-not-in-source'],
        [5, 'parent-not-migrated-locally']
      ],
      source_group_by_uuid: {
        'resolvable' => 10,
        'ungrouped-in-source' => nil,
        'parent-not-in-source' => 20,
        'parent-not-migrated-locally' => 30
      },
      parent_uuid_by_source_id: {
        10 => 'resolvable-parent-uuid',
        30 => 'unmigrated-parent-uuid'
      },
      target_parent_id_by_uuid: {
        'resolvable-parent-uuid' => 999
      }
    )

    expect(result.resolved).to eq([[1, 999]])
    expect(result.skipped_not_in_source).to eq(1)
    expect(result.skipped_source_also_ungrouped).to eq(1)
    expect(result.skipped_parent_not_migrated).to eq(2)
  end

  it 'does not resolve anything for an empty batch' do
    result = resolve(obs_batch: [])

    expect(result.resolved).to be_empty
    expect(result.skipped_not_in_source).to eq(0)
    expect(result.skipped_source_also_ungrouped).to eq(0)
    expect(result.skipped_parent_not_migrated).to eq(0)
  end
end
