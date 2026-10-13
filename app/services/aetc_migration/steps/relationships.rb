# frozen_string_literal: true

module AetcMigration
  module Steps
    # relationship (patient <-> guardian/relative). Needs both people migrated, so it waits until the
    # persons step has finished (in a dry run it covers relationships between the people of the trial).
    #   * types from relationship_type.json; types 18/19 and unmapped types are skipped and logged.
    #   * relationships pointing at a person missing from AETC are skipped (dangling_relationship).
    #   * active rows only, except rows belonging to a voided person/patient.
    class Relationships < Base
      def title
        'Relationships'
      end

      def waiting_for
        return if run.dry_run && checkpoint('persons').positive?
        return if persons_finished?

        "the persons step to finish (it has reached AETC person_id #{checkpoint('persons')} of #{max_person})"
      end

      def call
        @types = run.mappings.json('relationship_type.json')['mappings']
                    .select { |m| m['action'] == 'map' && m['target_id'] }
                    .to_h { |m| [m['source_id'], m['target_id']] }
        where = nil
        unless persons_finished?
          cap = checkpoint('persons').to_i
          where = "person_a <= #{cap} AND person_b <= #{cap}"
        end
        each_batch('relationship', 'relationship_id', where: where) { |rels, rec| migrate(rels, rec) }
        counts
      end

      private

      def max_person
        @max_person ||= sql.value("SELECT COALESCE(MAX(person_id), 0) FROM #{src('person')}").to_i
      end

      def persons_finished?
        checkpoint('persons') >= max_person
      end

      def migrate(rels, rec)
        people = rels.flat_map { |r| [r['person_a'], r['person_b']] }.uniq
        already = mapped_ids('relationship', rels.map { |r| r['relationship_id'] })
        persons = mapped_ids('person', people)
        in_aetc = sql.values("SELECT person_id FROM #{src('person')} WHERE person_id IN (#{sql.list(people)})").to_set
        owners = voided_owners(people)
        in_target = sql.ids_by_uuid(tgt('relationship'), 'relationship_id', rels.map { |r| r['uuid'] })

        pairs = rels.filter_map do |r|
          id = r['relationship_id']
          both = [r['person_a'], r['person_b']]
          next if already.key?(id)
          next if truthy?(r['voided']) && (both & owners.to_a).empty?

          if (missing = both.reject { |p| in_aetc.include?(p) }).any?
            rec.logged('relationship', id, 'dangling_relationship', "missing AETC person #{missing}")
          elsif (unmigrated = both.reject { |p| persons.key?(p) }).any?
            rec.logged('relationship', id, 'person_not_migrated', "AETC person #{unmigrated}")
          elsif !@types.key?(r['relationship'])
            rec.logged('relationship', id, 'relationship_type_unmapped', r['relationship'])
          elsif in_target.key?(r['uuid'])
            rec.logged('relationship', id, 'uuid_exists_in_target', "target relationship_id=#{in_target[r['uuid']]}")
          else
            voided = truthy?(r['voided'])
            [r, { 'person_a' => persons[r['person_a']], 'relationship' => @types[r['relationship']],
                  'person_b' => persons[r['person_b']], 'creator' => run.user_for(r['creator']),
                  'date_created' => r['date_created'] || EPOCH, 'voided' => voided ? 1 : 0,
                  'voided_by' => voided ? run.user_for(r['voided_by']) : nil, 'date_voided' => r['date_voided'],
                  'void_reason' => r['void_reason'], 'uuid' => r['uuid'] }]
          end
        end
        count('relationship', sql.insert(tgt('relationship'), pairs.map(&:last)))
        new_ids = sql.ids_by_uuid(tgt('relationship'), 'relationship_id', pairs.map { |_, row| row['uuid'] })
        pairs.each { |src, row| rec.mapped('relationship', src, 'relationship_id', new_ids.fetch(row['uuid']), row['uuid']) }
      end
    end
  end
end
