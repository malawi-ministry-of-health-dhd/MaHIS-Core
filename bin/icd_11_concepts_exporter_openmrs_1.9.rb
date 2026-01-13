require 'roda'

class ICD11Importer
  LOCALE = 'en'
  LOCALE_PREFERRED = 1
  CONCEPT_NAME_TYPE = 'FULLY_SPECIFIED'

  def initialize
    User.current = User.find_by(username: 'admin') || User.first

    @icd11_concept_class     = ConceptClass.find_by(name: 'Diagnosis')
    @icd11_concept_datatype  = ConceptDatatype.find_by(name: 'N/A')

    create_missing_openmrs_tables

    @concept_source = ConceptSource.find_or_initialize_by(name: 'ICD-11')
    @concept_source.assign_attributes(
      hl7_code: 'ICD11',
      description: 'International Classification of Diseases 11th Revision',
      uuid: 'a8a4f6e0-6dcb-11ec-90d6-0242ac120003',
      creator: User.current.id,
      date_created: Time.now
    )
    @concept_source.save!

    @concept_map_type = ConceptMapType.find_or_initialize_by(name: 'ICD-11 Code')
    @concept_map_type.assign_attributes(
      description: 'Mapping to ICD-11 code',
      uuid: 'b1b5f8e0-6dcb-11ec-90d6-0242ac120003',
      creator: User.current.id
    )
    @concept_map_type.save!

    @concept_source = ConceptSource.find_by(name: 'ICD-11')
    @concept_map_type = ConceptMapType.find_by(name: 'ICD-11 Code')
  end

  def handle_insert_icd11(batch_size: 500)
    file_path = Rails.root.join('db/ICD11', 'LinearizationMiniOutput-MMS-en.xlsx')
    xlsx      = Roo::Excelx.new(file_path)
    sheet     = xlsx.sheet(0)

    dash_regex = /\A[- ]*/
    int_regex  = /\A\d+\z/
    parent_cache = {}

    total_rows = sheet.last_row - 1
    processed  = 0
    start_time = Time.now

    puts "Starting ICD-11 import (#{total_rows} rows), batch size: #{batch_size}"

    batch_rows = []

    ActiveRecord::Base.transaction do
      sheet.each_with_index do |row, index|
        next if index.zero?
        next if row.nil? || row.length < 2

        # --- parse row ---
        code = row[0]&.to_s&.strip
        raw  = row[1]&.to_s
        next if raw.blank?

        leading_part = raw[dash_regex] || ''
        title        = raw.sub(dash_regex, '').strip
        next if title.blank?

        class_kind = row[2]&.to_s&.strip
        depth      = row[3].to_s.match?(int_regex) ? row[3].to_i : nil
        sort_weight = leading_part.count('-')

        icd_class, is_set =
          case class_kind
          when 'chapter'  then ['Chapter', 0]
          when 'block'    then ['Block', 1]
          when 'category' then ['Category', 1]
          else
            next
          end

        batch_rows << {
          code: code,
          title: title,
          icd_class: icd_class,
          is_set: is_set,
          depth: depth,
          class_kind: class_kind,
          sort_weight: sort_weight
        }

        # --- process batch ---
        next unless batch_rows.size >= batch_size

        insert_icd11_batch_bulk(batch_rows, parent_cache)
        processed += batch_rows.size
        batch_rows.clear

        percent = ((processed.to_f / total_rows) * 100).round(1)
        elapsed = (Time.now - start_time).round(1)
        puts "Processed #{processed}/#{total_rows} (#{percent}%) – elapsed #{elapsed}s"
      end

      # insert remaining rows
      if batch_rows.any?
        insert_icd11_batch_bulk(batch_rows, parent_cache)
        processed += batch_rows.size
        puts "Processed #{processed}/#{total_rows} (100%) – elapsed #{(Time.now - start_time).round(1)}s"
      end
    end

    normalize_concept_set_sort_weights
    total_time = (Time.now - start_time).round(1)
    puts "ICD-11 import completed: #{processed} rows in #{total_time}s"
  end

  # -------------------------------
  # Bulk insert helper
  # -------------------------------
  def insert_icd11_batch_bulk(rows, parent_cache)
    # --- 1️⃣ Bulk insert concepts ---
    require 'securerandom'
    concept_records = rows.map do |r|
      {
        uuid: SecureRandom.uuid,
        class_id: 4, # Diagnosis
        datatype_id: 4, # N/A
        creator: 1,
        date_created: Time.current,
        date_changed: Time.current,
        short_name: r[:icd_class]
      }
    end

    Concept.insert_all(concept_records)

    # Map inserted concept IDs back to rows using UUIDs
    uuids = concept_records.map { |r| r[:uuid] }
    uuid_to_id = Concept.where(uuid: uuids).pluck(:uuid, :concept_id).to_h

    rows.each_with_index do |r, idx|
      r[:concept_id] = uuid_to_id[concept_records[idx][:uuid]]
    end

    # Update local concept cache with newly inserted concepts
    inserted_concepts = Concept.where(uuid: uuids).pluck(:concept_id, :short_name)
    inserted_concepts.each do |concept_id, short_name|
      parent_cache[:concepts_by_name] ||= {}
      parent_cache[:concepts_by_name][short_name] ||= []
      parent_cache[:concepts_by_name][short_name] << concept_id
      # Sort in descending order for quick access to latest
      parent_cache[:concepts_by_name][short_name].sort!.reverse!
    end

    # --- 1️⃣.5️⃣ Bulk create concept names ---
    concept_name_records = []
    rows.each do |r|
      concept_name_records << {
        concept_id: r[:concept_id],
        name: r[:title],
        locale: LOCALE,
        locale_preferred: LOCALE_PREFERRED,
        concept_name_type: CONCEPT_NAME_TYPE,
        creator: 1,
        date_created: Time.current,
        uuid: SecureRandom.uuid
      }
    end

    ConceptName.insert_all(concept_name_records) if concept_name_records.any?

    # --- 2️⃣ Prepare concept sets for bulk insert ---
    concept_set_records = []

    # Initialize hierarchy stack on first batch
    parent_cache[:hierarchy_stack] ||= {}

    rows.each do |r|
      # Update the hierarchy stack BEFORE skipping chapters
      # so that blocks/categories can find their chapter parents
      parent_cache[:hierarchy_stack][r[:sort_weight]] = r[:concept_id]

      next if r[:class_kind] == 'chapter'

      # Use sort_weight (dash count) to determine parent
      # A concept with sort_weight N is parent of concept with sort_weight N+1
      next unless r[:sort_weight] > 0

      # Find the last concept with sort_weight = r[:sort_weight] - 1
      parent_id = parent_cache[:hierarchy_stack][r[:sort_weight] - 1]

      next unless parent_id

      concept_set_records << {
        concept_set: parent_id,
        concept_id: r[:concept_id],
        sort_weight: 1, # Will be renormalized later
        uuid: SecureRandom.uuid,
        creator: 1,
        date_created: Time.current
      }
    end

    # --- 3️⃣ Bulk insert concept sets ---
    ConceptSet.insert_all(concept_set_records) if concept_set_records.any?
  end

  private

  def create_concept(name, code = nil, klass = nil, is_set = 0, description = nil)
    concept_name = ConceptName.find_by(name: name)
    concept = concept_name&.concept

    # Create new concept if concept name does not exist
    if concept.blank?
      concept = Concept.create!(
        datatype_id: @icd11_concept_datatype.concept_datatype_id,
        class_id: @icd11_concept_class.concept_class_id,
        is_set: is_set,
        creator: User.current.user_id,
        short_name: klass,
        description: description,
        date_created: Time.now
      )

      ConceptName.create!(
        name: name,
        concept_id: concept.concept_id,
        locale: LOCALE,
        locale_preferred: LOCALE_PREFERRED,
        concept_name_type: CONCEPT_NAME_TYPE,
        creator: User.current.user_id
      )
    else
      concept.update!(
        description: description,
        is_set: is_set,
        class_id: @icd11_concept_class.concept_class_id,
        datatype_id: @icd11_concept_datatype.concept_datatype_id,
        date_changed: Time.now,
        changed_by: User.current.id
      )
    end

    create_concept_map(concept, code) if code.present? && !code.strip.empty?

    concept
  end

  def add_to_concept_set(parent_concept, child_concept, sort_weight)
    return if parent_concept.blank? || child_concept.blank?

    ConceptSetMember.find_or_create_by(
      concept_set_id: parent_concept.concept_id,
      concept_id: child_concept.concept_id
    ) do |csm|
      csm.sort_weight = sort_weight
      csm.created_at 	= Time.now
      csm.updated_at 	= Time.now
      csm.uuid        = SecureRandom.uuid
    end
  end

  def get_last_category(concept_class, target_concept_id, sort_weight = nil)
    concepts = Concept.where(short_name: concept_class)
                      .where.not(concept_id: target_concept_id)
                      .order(concept_id: :desc)

    return concepts.first if concept_class == 'Chapter'

    concepts.each do |concept|
      concept_set = ConceptSet.where(concept_id: concept.concept_id)
                              .order(concept_set_id: :desc)
                              .first
      return concept if concept_set&.sort_weight.to_i < sort_weight.to_i
    end
    nil
  end

  def get_last_category_from_cache(concept_class, target_concept_id, parent_cache, sort_weight = nil)
    # Use in-memory cache instead of database queries
    cached_concepts = parent_cache[:concepts_by_name] || {}
    concept_ids = cached_concepts[concept_class] || []

    # Track parents and their max sort_weight
    parent_cache[:parent_sort_weights] ||= {}

    # Filter out target concept and find first valid parent
    concept_id = concept_ids.find do |cid|
      cid != target_concept_id &&
        (concept_class == 'Chapter' || parent_cache[:parent_sort_weights][cid].to_i < sort_weight.to_i)
    end

    # If we found a valid parent, update its sort weight tracking
    parent_cache[:parent_sort_weights][concept_id] = sort_weight if concept_id

    concept_id
  end

  def create_concept_map(concept, code)
    concept_map = ConceptMap.create(
      concept_id: concept.concept_id,
      concept_source_id: @concept_source.concept_source_id,
      concept_map_type_id: @concept_map_type.concept_map_type_id,
      concept_code: code,
      creator: User.current.id,
      date_created: Time.now,
      uuid: SecureRandom.uuid
    )

    return if concept_map.persisted?

    puts "Failed to create Concept: #{concept.concept_id} ConceptMap for code: #{code}"
    puts concept_map.errors.full_messages
    raise 'ConceptMap creation failed'
  end

  def create_missing_openmrs_tables
    conn = ActiveRecord::Base.connection

    unless conn.table_exists?(:concept_source)
      conn.create_table :concept_source, primary_key: 'concept_source_id' do |t|
        t.string  :name, null: false
        t.string  :hl7_code
        t.text    :description
        t.boolean :retired, default: false
        t.string  :uuid, null: false
        t.timestamps
      end
      conn.add_index :concept_source, :name, unique: true
    end

    unless conn.table_exists?(:concept_map_type)
      conn.create_table :concept_map_type, primary_key: 'concept_map_type_id' do |t|
        t.string  :name, null: false
        t.text    :description
        t.boolean :retired, default: false
        t.integer :creator
        t.string  :uuid, null: false
        t.timestamps
      end
      conn.add_index :concept_map_type, :name, unique: true
    end

    unless conn.table_exists?(:concept_map)
      conn.create_table :concept_map, primary_key: 'concept_map_id' do |t|
        t.integer :concept_id, null: false
        t.integer :concept_source_id, null: false
        t.integer :concept_map_type_id, null: false
        t.string  :concept_code, null: false
        t.string  :uuid, null: false
        t.timestamps
      end

      conn.add_index :concept_map,
                     %i[concept_id concept_source_id concept_code],
                     unique: true,
                     name: 'idx_concept_map_unique'
    end

    unless conn.table_exists?(:concept_description)
      conn.create_table :concept_description, primary_key: 'concept_description_id' do |t|
        t.integer :concept_id, null: false
        t.text    :description, null: false
        t.string  :locale, null: false
        t.string  :uuid, null: false
        t.timestamps
      end
    end

    unless conn.table_exists?(:concept_name_tag)
      conn.create_table :concept_name_tag, primary_key: 'concept_name_tag_id' do |t|
        t.string :tag, null: false
        t.text   :description
        t.string :uuid, null: false
        t.timestamps
      end
      conn.add_index :concept_name_tag, :tag, unique: true
    end

    unless conn.table_exists?(:concept_name_tag_map)
      conn.create_table :concept_name_tag_map, primary_key: 'concept_name_tag_map_id' do |t|
        t.integer :concept_name_id, null: false
        t.integer :concept_name_tag_id, null: false
      end

      conn.add_index :concept_name_tag_map,
                     %i[concept_name_id concept_name_tag_id],
                     unique: true,
                     name: 'idx_name_tag_map_unique'
    end

    unless conn.table_exists?(:concept_set)
      conn.create_table :concept_set, primary_key: 'concept_set_id' do |t|
        t.integer :concept_set, null: false
        t.integer :concept_id, null: false
        t.float   :sort_weight
        t.string  :uuid, null: false
        t.timestamps
      end

      conn.add_index :concept_set,
                     %i[concept_set concept_id],
                     unique: true,
                     name: 'idx_concept_set_unique'
    end

    upgrade_concept_map_table
    upgrade_concept_source_table
  end

  def upgrade_concept_map_table
    conn = ActiveRecord::Base.connection

    return unless conn.table_exists?(:concept_map)

    # Rename columns
    conn.rename_column :concept_map, :source, :concept_source_id if conn.column_exists?(:concept_map, :source)
    conn.rename_column :concept_map, :source_code, :concept_code if conn.column_exists?(:concept_map, :source_code)

    # Add missing columns
    conn.add_column :concept_map, :concept_map_type_id, :integer unless conn.column_exists?(:concept_map,
                                                                                            :concept_map_type_id)
    conn.add_column :concept_map, :created_at, :datetime unless conn.column_exists?(:concept_map, :created_at)
    conn.add_column :concept_map, :updated_at, :datetime unless conn.column_exists?(:concept_map, :updated_at)

    # Optional: add indexes
    unless conn.index_exists?(:concept_map,
                              %i[concept_id concept_source_id concept_code], unique: true)
      conn.add_index :concept_map, %i[concept_id concept_source_id concept_code],
                     unique: true, name: 'idx_concept_map_unique'
    end
  end

  def upgrade_concept_source_table
    conn = ActiveRecord::Base.connection
    return unless conn.table_exists?(:concept_source)

    conn.rename_column :concept_source, :name, :name unless conn.column_exists?(:concept_source, :name)
    conn.rename_column :concept_source, :hl7_code, :hl7_code unless conn.column_exists?(:concept_source, :hl7_code)
    conn.add_column :concept_source, :retired, :boolean, default: false unless conn.column_exists?(:concept_source,
                                                                                                   :retired)
    conn.add_column :concept_source, :uuid, :string unless conn.column_exists?(:concept_source, :uuid)
  end

  def normalize_concept_set_sort_weights
    # Group all members by concept_set
    members_by_set = ConceptSet
                     .select(:concept_set_id, :concept_set)
                     .order(:concept_set, :concept_set_id)
                     .group_by(&:concept_set)

    # Build bulk update cases
    updates = []
    members_by_set.each do |_set_id, members|
      members.each_with_index do |member, index|
        updates << { id: member.concept_set_id, sort_weight: index + 1 }
      end
    end

    # Bulk update in batches
    updates.each_slice(1000) do |batch|
      sql_cases = batch.map { |u| "WHEN #{u[:id]} THEN #{u[:sort_weight]}" }.join(' ')
      ids = batch.map { |u| u[:id] }.join(',')

      ActiveRecord::Base.connection.execute(
        "UPDATE concept_set SET sort_weight = CASE concept_set_id #{sql_cases} END WHERE concept_set_id IN (#{ids})"
      )
    end
  end
end

ICD11Importer.new.handle_insert_icd11
