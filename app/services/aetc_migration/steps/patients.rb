# frozen_string_literal: true

module AetcMigration
  module Steps
    # patient and patient_identifier, for AETC patients whose person the persons step has migrated.
    #   * MaHIS patient_id = the new person_id. Voided patients are migrated as voided.
    #   * Identifiers: active rows only, except that voided patients/persons bring all their rows.
    #   * Types from patient_identifier_type.json (National id and DDE document ID -> Old identification
    #     number; Dummy ID skipped); locations from location.json.
    #   * A value shared by more than one AETC patient is loaded and flagged (duplicate_identifier);
    #     a value MaHIS already has on another patient is loaded and flagged (identifier_exists_in_target).
    class Patients < Base
      def title
        'Patients'
      end

      def waiting_for
        'the persons step' if checkpoint('persons').zero?
      end

      def call
        load_rules
        @duplicates = duplicate_identifiers
        upto = [checkpoint('persons'), run.cap].compact.min
        each_batch('patient', 'patient_id', upto: upto) { |patients, rec| migrate(patients, rec) }
        counts
      end

      private

      def load_rules
        types = run.mappings.json('patient_identifier_type.json')['mappings']
        @types = types.select { |m| %w[map map_validated].include?(m['action']) && m['target_id'] }
                      .to_h { |m| [m['source_id'], m['target_id']] }
        @skipped_types = types.select { |m| m['action'] == 'skip' }.to_set { |m| m['source_id'] }
        @locations = run.mappings.json('location.json')['mappings']
                        .select { |m| m['action'] == 'map' && m['target_id'] }
                        .to_h { |m| [m['source_id'], m['target_id']] }
      end

      # [type, value] pairs held by more than one AETC patient among active identifiers.
      def duplicate_identifiers
        return Set.new if @types.empty?

        sql.select(<<~SQL).to_set { |r| [r['identifier_type'], r['identifier']] }
          SELECT identifier_type, identifier FROM #{src('patient_identifier')}
          WHERE voided = 0 AND identifier_type IN (#{sql.list(@types.keys)})
          GROUP BY identifier_type, identifier HAVING COUNT(DISTINCT patient_id) > 1
        SQL
      end

      def migrate(patients, rec)
        ids = patients.map { |p| p['patient_id'] }
        already = mapped_ids('patient', ids)
        persons = mapped_ids('person', ids)
        in_target = sql.values("SELECT patient_id FROM #{tgt('patient')} WHERE patient_id IN (#{sql.list(persons.values)})")
                       .to_set
        todo = patients.select do |p|
          id = p['patient_id']
          if already.key?(id)
            false
          elsif !persons.key?(id)
            rec.logged('patient', id, 'person_not_migrated')
            false
          elsif in_target.include?(persons[id])
            rec.logged('patient', id, 'patient_exists_in_target', "target patient_id=#{persons[id]}")
            false
          else
            true
          end
        end
        return if todo.empty?

        rows = todo.map { |p| { 'patient_id' => persons[p['patient_id']], 'tribe' => nil, **audit(p), **changed(p) } }
        count('patient', sql.insert(tgt('patient'), rows))
        todo.each { |p| rec.mapped('patient', p, 'patient_id', persons[p['patient_id']], nil) }
        insert_identifiers(todo.map { |p| p['patient_id'] }, persons, rec)
      end

      def insert_identifiers(ids, persons, rec)
        owners = voided_owners(ids)
        identifiers = sql.select("SELECT * FROM #{src('patient_identifier')} WHERE patient_id IN (#{sql.list(ids)}) " \
                                 'ORDER BY patient_identifier_id')
        pairs = identifiers.filter_map { |i| identifier_row(i, persons, owners, rec) }
        flag_existing(pairs, rec)
        count('patient_identifier', sql.insert(tgt('patient_identifier'), pairs.map(&:last)))
        new_ids = sql.ids_by_uuid(tgt('patient_identifier'), 'patient_identifier_id', pairs.map { |_, r| r['uuid'] })
        pairs.each do |src, row|
          rec.mapped('patient_identifier', src, 'patient_identifier_id', new_ids.fetch(row['uuid']), row['uuid'])
        end
      end

      def identifier_row(ident, persons, owners, rec)
        id = ident['patient_identifier_id']
        return if truthy?(ident['voided']) && !owners.include?(ident['patient_id'])

        type_id = @types[ident['identifier_type']]
        location_id = @locations[ident['location_id']]
        if @skipped_types.include?(ident['identifier_type'])
          rec.logged('patient_identifier', id, 'identifier_type_skipped', ident['identifier_type'])
        elsif type_id.nil?
          rec.logged('patient_identifier', id, 'identifier_type_unmapped', ident['identifier_type'])
        elsif location_id.nil?
          rec.logged('patient_identifier', id, 'location_unmapped', ident['location_id'])
        else
          if !truthy?(ident['voided']) && @duplicates.include?([ident['identifier_type'], ident['identifier']])
            rec.logged('patient_identifier', id, 'duplicate_identifier',
                       "type #{ident['identifier_type']} value #{ident['identifier']}")
          end
          [ident, { 'patient_id' => persons[ident['patient_id']], 'identifier' => ident['identifier'],
                    'identifier_type' => type_id, 'preferred' => truthy?(ident['preferred']) ? 1 : 0,
                    'location_id' => location_id, **audit(ident), 'uuid' => ident['uuid'] }]
        end
      end

      # Values MaHIS already holds for a different patient: loaded, but flagged for review.
      def flag_existing(pairs, rec)
        active = pairs.reject { |_, r| r['voided'] == 1 }
        active.group_by { |_, r| r['identifier_type'] }.each do |type_id, group|
          held = sql.select("SELECT identifier, patient_id FROM #{tgt('patient_identifier')} WHERE voided = 0 " \
                            "AND identifier_type = #{type_id.to_i} " \
                            "AND identifier IN (#{sql.list(group.map { |_, r| r['identifier'] })})")
                    .group_by { |r| r['identifier'] }
          group.each do |src, row|
            others = (held[row['identifier']] || []).map { |r| r['patient_id'] } - [row['patient_id']]
            next if others.empty?

            rec.logged('patient_identifier', src['patient_identifier_id'], 'identifier_exists_in_target',
                       "type #{type_id} value #{row['identifier']}")
          end
        end
      end
    end
  end
end
