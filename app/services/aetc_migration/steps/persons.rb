# frozen_string_literal: true

module AetcMigration
  module Steps
    # person, person_name, person_address, person_attribute, in batches of AETC persons.
    #   * Persons that are only AETC users (not patients, in no relationship) are skipped.
    #   * Child rows: active rows only, except that voided persons/patients bring all their rows.
    #   * Gender via value_normalization.json (unknown -> NULL). Persons without a name load without one.
    #   * The name marked preferred is the latest active one.
    #   * Each person's AETC home and current address rows are merged into one MaHIS row (person_address.json).
    #   * person_name_code is not written here: rake aetc:post_load indexes the names.
    class Persons < Base
      NAME_COLUMNS = %w[prefix given_name middle_name family_name_prefix family_name family_name2
                        family_name_suffix degree].freeze
      HOME_MARKERS = %w[address3 state_province county_district].freeze

      def title
        'Persons'
      end

      def call
        load_rules
        @user_only = user_only_persons
        each_batch('person', 'person_id', upto: run.cap) { |persons, rec| migrate(persons, rec) }
        counts
      end

      private

      def load_rules
        norm = run.mappings.json('value_normalization.json')
        @gender = norm.dig('gender', 'map')
        @country = norm.dig('country', 'map')
        @country_nulls = norm.dig('country', 'null_values').map(&:downcase).to_set
        @text_nulls = norm.dig('text_null_values', 'values').map(&:downcase).to_set
        address = run.mappings.json('person_address.json')
        @address_columns = address['column_map']
        @address_nulls = address['null_values'].map(&:downcase).to_set
        @address_max = address['target_max_length']
        @address_sources = @address_columns.flat_map { |c| c['source'].map { |s| s['column'] } }.uniq.sort
        @attribute_types = run.mappings.json('person_attribute_type.json')['mappings']
                              .select { |m| m['action'] == 'map' && m['target_id'] }
                              .to_h { |m| [m['source_id'], m['target_id']] }
      end

      def user_only_persons
        sql.values(<<~SQL).to_set
          SELECT u.person_id FROM #{src('users')} u
          WHERE u.person_id NOT IN (SELECT patient_id FROM #{src('patient')})
            AND NOT EXISTS (SELECT 1 FROM #{src('relationship')} r WHERE r.person_a = u.person_id)
            AND NOT EXISTS (SELECT 1 FROM #{src('relationship')} r WHERE r.person_b = u.person_id)
        SQL
      end

      def migrate(persons, rec)
        already = mapped_ids('person', persons.map { |p| p['person_id'] })
        in_target = sql.ids_by_uuid(tgt('person'), 'person_id', persons.map { |p| p['uuid'] })
        todo = persons.reject do |p|
          id = p['person_id']
          next true if already.key?(id)

          if @user_only.include?(id)
            rec.logged('person', id, 'user_only_person')
          elsif in_target.key?(p['uuid'])
            rec.logged('person', id, 'uuid_exists_in_target', "target person_id=#{in_target[p['uuid']]}")
          else
            next false
          end
          true
        end
        return if todo.empty?

        person_map = insert_persons(todo, rec)
        ids = person_map.keys
        owners = voided_owners(ids)
        insert_names(ids, person_map, owners, rec)
        insert_addresses(ids, person_map, owners, rec)
        insert_attributes(ids, person_map, owners, rec)
      end

      def insert_persons(todo, rec)
        rows = todo.map do |p|
          rec.logged('person', p['person_id'], 'cause_of_death_dropped', p['cause_of_death']) unless p['cause_of_death'].nil?
          { 'gender' => gender(p['gender']), 'birthdate' => p['birthdate'],
            'birthdate_estimated' => truthy?(p['birthdate_estimated']) ? 1 : 0, 'dead' => truthy?(p['dead']) ? 1 : 0,
            'death_date' => p['death_date'], 'cause_of_death' => nil, **audit(p), **changed(p), 'uuid' => p['uuid'] }
        end
        count('person', sql.insert(tgt('person'), rows))
        new_ids = sql.ids_by_uuid(tgt('person'), 'person_id', todo.map { |p| p['uuid'] })
        todo.to_h do |p|
          rec.mapped('person', p, 'person_id', new_ids.fetch(p['uuid']), p['uuid'])
          [p['person_id'], new_ids.fetch(p['uuid'])]
        end
      end

      def insert_names(ids, person_map, owners, rec)
        names = rows_by_person('person_name', ids, 'person_name_id')
        pairs = ids.flat_map do |id|
          keep = names.fetch(id, []).select { |n| !truthy?(n['voided']) || owners.include?(id) }
          active = keep.reject { |n| truthy?(n['voided']) }
          latest = active.max_by { |n| [n['date_created'] || EPOCH, n['person_name_id']] }
          keep.map do |n|
            preferred = latest ? (n.equal?(latest) ? 1 : 0) : (truthy?(n['preferred']) ? 1 : 0)
            [n, { 'preferred' => preferred, 'person_id' => person_map[id], **n.slice(*NAME_COLUMNS),
                  **audit(n), **changed(n), 'uuid' => n['uuid'] }]
          end
        end
        insert_mapped('person_name', 'person_name_id', pairs, rec)
      end

      def insert_addresses(ids, person_map, owners, rec)
        addresses = rows_by_person('person_address', ids, 'person_address_id')
        merged = ids.filter_map do |id|
          merge_address(addresses.fetch(id, []), person_map[id], owners.include?(id), rec)
        end
        count('person_address', sql.insert(tgt('person_address'), merged.map(&:last)))
        new_ids = sql.ids_by_uuid(tgt('person_address'), 'person_address_id', merged.map { |_, row| row['uuid'] })
        merged.each do |used, row|
          used.each { |src| rec.mapped('person_address', src, 'person_address_id', new_ids.fetch(row['uuid']), row['uuid']) }
        end
      end

      def insert_attributes(ids, person_map, owners, rec)
        attributes = sql.select("SELECT * FROM #{src('person_attribute')} WHERE person_id IN (#{sql.list(ids)}) " \
                                'ORDER BY person_attribute_id')
        pairs = attributes.filter_map do |a|
          next if truthy?(a['voided']) && !owners.include?(a['person_id'])

          type_id = @attribute_types[a['person_attribute_type_id']]
          value = text(a['value'])
          if type_id.nil?
            rec.logged('person_attribute', a['person_attribute_id'], 'attribute_type_unmapped', a['person_attribute_type_id'])
          elsif value.nil?
            rec.logged('person_attribute', a['person_attribute_id'], 'empty_value', a['value'])
          else
            [a, { 'person_id' => person_map[a['person_id']], 'value' => value, 'person_attribute_type_id' => type_id,
                  **audit(a), **changed(a), 'uuid' => a['uuid'] }]
          end
        end
        insert_mapped('person_attribute', 'person_attribute_id', pairs, rec)
      end

      # One MaHIS address from a person's AETC rows. Returns [used AETC rows, MaHIS row] or nil.
      def merge_address(rows, person_id, owner_voided, rec)
        kinds = { 'home' => [], 'current' => [] }
        rows.each do |r|
          next if truthy?(r['voided']) && !owner_voided

          values = @address_sources.to_h { |c| [c, address_value(r[c])] }
          if values.values.all?(&:nil?)
            rec.logged('person_address', r['person_address_id'], 'empty_address')
            next
          end
          kinds[HOME_MARKERS.any? { |c| values[c] } ? 'home' : 'current'] << [r, values]
        end

        chosen = {}
        kinds.each do |kind, items|
          next if items.empty?

          items.sort_by! { |r, _| [r['date_created'] || EPOCH, r['person_address_id']] }
          chosen[kind] = items.last
          items[0...-1].each do |r, _|
            rec.logged('person_address', r['person_address_id'], 'superseded_address',
                       "older #{kind} row for person #{r['person_id']}")
          end
        end
        return if chosen.empty?

        target = address_fields(chosen, rec)
        return if target.values.all?(&:nil?)

        used = chosen.values.map(&:first)
        primary = (chosen['home'] || chosen['current']).first
        all_voided = used.all? { |r| truthy?(r['voided']) }
        row = { 'person_id' => person_id, 'preferred' => 1, **target, 'creator' => run.migration_user_id,
                'date_created' => used.map { |r| r['date_created'] || EPOCH }.min,
                'voided' => all_voided ? 1 : 0, 'voided_by' => all_voided ? run.migration_user_id : nil,
                'date_voided' => all_voided ? primary['date_voided'] : nil,
                'void_reason' => all_voided ? primary['void_reason'] : nil, 'uuid' => primary['uuid'] }
        [used, row]
      end

      def address_fields(chosen, rec)
        @address_columns.to_h do |column|
          value = nil
          column['source'].each do |source|
            item = chosen[source['row']]
            value = item&.last&.dig(source['column'])
            break if value
          end
          if column['target'] == 'country'
            value, unmapped = country(value)
            rec.logged('person_address', chosen['home'].first['person_address_id'], 'country_unmapped', value) if unmapped
          end
          limit = @address_max[column['target']]
          if value && limit && value.length > limit
            rec.logged('person_address', chosen.values.first.first['person_address_id'], 'value_truncated',
                       "#{column['target']}=#{value}")
            value = value[0, limit]
          end
          [column['target'], value]
        end
      end

      def rows_by_person(table, ids, id_column)
        sql.select("SELECT * FROM #{src(table)} WHERE person_id IN (#{sql.list(ids)}) ORDER BY person_id, #{id_column}")
           .group_by { |r| r['person_id'] }
      end

      def insert_mapped(entity, id_column, pairs, rec)
        count(entity, sql.insert(tgt(entity), pairs.map(&:last)))
        new_ids = sql.ids_by_uuid(tgt(entity), id_column, pairs.map { |_, row| row['uuid'] })
        pairs.each { |src, row| rec.mapped(entity, src, id_column, new_ids.fetch(row['uuid']), row['uuid']) }
      end

      def gender(value)
        value.nil? ? nil : @gender[value.strip]
      end

      def address_value(value)
        return nil if value.nil?

        value = value.strip
        @address_nulls.include?(value.downcase) ? nil : value
      end

      # [value, unmapped?]
      def country(value)
        value = address_value(value)
        return [nil, false] if value.nil? || @country_nulls.include?(value.downcase)
        return [@country[value], false] if @country.key?(value)

        [value, true]
      end

      def text(value)
        return nil if value.nil?

        value = value.strip
        @text_nulls.include?(value.downcase) ? nil : value
      end
    end
  end
end
