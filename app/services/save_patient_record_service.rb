# app/services/save_patient_record_service.rb
# frozen_string_literal: true

class SavePatientRecordService
  include CouchdbSync

  RequiredFields = Struct.new(:program_id, :provider_id, :location_id, :encounter_datetime)
  PatientIds     = Struct.new(:national_id, :ichis_id, :birth_id)

  ENCOUNTER_TYPE_MAPPING = {
    lab_orders:           'LAB ORDERS',
    lab_results:          'LAB RESULTS',
    medical_history:      'MEDICAL HISTORY',
    patient_registration: 'PATIENT REGISTRATION',
    treatment:            'TREATMENT',
  }.freeze

  def create_patient_record(record)
    strip_derived_patient_fields!(record)
    ensure_encounter_datetime!(record)
    should_top_up_dde_ids = should_top_up_dde_ids_after_save?(record)

    required_fields = extract_required_fields(record)
    return "required fields missing" unless required_fields_present?(required_fields)

    ids      = extract_patient_ids(record)
    managers = initialize_managers

    identity_data = managers[:identity_manager].save_person_information(record)
    patient_id    = identity_data[:patient_id]
    return "Patient ID not found" unless patient_id
    return "Patient ID not found" unless Patient.exists?(patient_id: patient_id)

    unless managers[:identity_manager].validate_ids(ids.national_id, ids.birth_id, ids.ichis_id)
      return "ID Validation Failed"
    end

    overall_sync_status = 'synced'
    operation_results   = {}

    begin
      operation_results = execute_patient_operations(patient_id, record, managers)

      if operation_results.any? { |_k, r| r.failed? }
        failed_ops = operation_results.select { |_k, r| r.failed? }.keys.join(', ')
        Rails.logger.error("Failures in: #{failed_ops} for patient #{patient_id}")
        overall_sync_status = 'partial_failed'
      else
        Rails.logger.info("All sub-operations successfully processed for patient #{patient_id}.")
      end
    rescue StandardError => e
      Rails.logger.error("Unhandled error for patient #{patient_id}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      overall_sync_status = 'failed'
      raise
    end

    # Voiding the patient row makes every default-scoped Patient lookup below
    # (find_patient, primary-identifier check, etc.) come back empty, since
    # VoidableRecord's default_scope excludes voided rows. Finalize from the
    # already-known record instead of running it through the live-patient
    # rebuild path.
    if operation_results[:void_patient]&.success?
      return finalize_voided_patient_record(patient_id, record, operation_results, overall_sync_status)
    end

    history_base = resolve_history_base(patient_id, record)
    patient_record = build_and_save_patient_record(patient_id, record, operation_results, overall_sync_status,
                                                   created_lab_orders: managers[:lab_data_manager].created_lab_orders,
                                                   couch_base: history_base)
    ensure_primary_identifier_persisted!(patient_id, patient_record)
    enqueue_post_save_side_effects(patient_id, record, operation_results)

    if couchdb_configured?
      begin
        patient_record["_id"] = patient_record["ID"]
        sync_to_couchdb(patient_record, "patients_records", "#{patient_record["ID"]}")
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
        Rails.logger.warn("CouchDB connection error during patient record sync for #{patient_record["ID"]}: #{e.class}: #{e.message}")
      rescue StandardError => e
        Rails.logger.error("CouchDB sync failed for patient #{patient_record["ID"]}: #{e.class}: #{e.message}")
      end
    end
    enqueue_dde_id_top_up(patient_record, record) if should_top_up_dde_ids && couchdb_configured?

    patient_record
  end

  private

  # Best-effort synchronous update of the ncd_patient_index projection for the
  # saved record. Mirrors CouchdbChangesListener#maintain_ncd_patient_index for
  # the REST path. Non-NCD records yield no projection and are skipped.
  def refresh_ncd_patient_index(patient_record)
    return unless NcdService::NcdPatientIndex.configured?

    NcdService::NcdPatientIndex.upsert_records([patient_record])
  rescue StandardError => e
    Rails.logger.error("[NCD] Failed to refresh NCD patient index for #{patient_record['ID']}: #{e.message}")
  end

  # Mark an online (REST) patient record as already listener-processed so the
  # CouchDB changes listener skips it. Uses the same fields the listener stamps
  # (see CouchdbChangesListener#update_couchdb_with_retry). An offline edit later
  # resets processed_by_listener to false on the client, so future edits are still
  # picked up.
  def mark_online_record_listener_processed!(patient_record)
    patient_record["processed_by_listener"] = true
    patient_record["listener_processed_at"] = Time.current.iso8601
    patient_record["processed_by_db"] = "patients_records"
  end

  def extract_required_fields(record)
    RequiredFields.new(
      program_id:           record.dig(:program_id),
      provider_id:          record.dig(:provider_id),
      location_id:          record.dig(:location_id),
      encounter_datetime:   record.dig(:encounter_datetime)
    )
  end

  def required_fields_present?(required_fields)
    required_fields.to_h.values.all?(&:present?)
  end

  # When a record arrives without a top-level encounter_datetime (e.g. one
  # re-written by an electronic lab-result write-back), fall back to the most
  # recent clinical timestamp already present in the record, and only to the
  # current time if the record carries no usable date at all. This keeps the
  # required-fields guard satisfied while preserving the real clinical date.
  def ensure_encounter_datetime!(record)
    return record unless record.respond_to?(:[]=)
    return record if parse_time_safe(record_value(record, :encounter_datetime)).present?

    fallback = latest_record_datetime(record) || Time.current
    record[:encounter_datetime] = fallback.iso8601

    Rails.logger.warn(
      "[SavePatientRecord] encounter_datetime missing; defaulted to #{record[:encounter_datetime]} " \
      "for #{record_value(record, :ID) || record_value(record, :patientID)}"
    )
    record
  end

  # Most recent non-future timestamp drawn from the record's own clinical data.
  # Only "when it happened" fields are considered (encounter/obs datetimes, lab
  # order dates, medication encounter/start dates) — never future-dated fields
  # such as appointment dates or drug end dates — and anything after now is
  # discarded so the fallback can never land in the future.
  def latest_record_datetime(record)
    now        = Time.current
    candidates = collect_obs_datetimes(record_value(record, :observations))

    lab_orders = record_value(record, :labOrders)
    if lab_orders
      (Array(record_value(lab_orders, :saved)) + Array(record_value(lab_orders, :unsaved))).each do |order|
        candidates << record_value(order, :order_date)
      end
    end

    medication_orders = record_value(record, :MedicationOrder)
    if medication_orders
      (Array(record_value(medication_orders, :saved)) + Array(record_value(medication_orders, :unsaved))).each do |order|
        candidates << record_value(order, :encounter_date)
        candidates << record_value(order, :start_date)
      end
    end

    candidates.filter_map { |value| parse_time_safe(value) }
              .reject     { |time| time > now }
              .max
  end

  def collect_obs_datetimes(observations)
    Array(observations).flat_map do |group|
      Array(record_value(group, :obs)).flat_map { |obs| extract_obs_times(obs) }
    end
  end

  def extract_obs_times(obs)
    times = [record_value(obs, :encounter_datetime), record_value(obs, :obs_datetime)]
    Array(record_value(obs, :children)).each { |child| times.concat(extract_obs_times(child)) }
    times
  end

  def parse_time_safe(value)
    return nil if value.blank?
    return value if value.is_a?(Time) || value.is_a?(DateTime)

    Time.zone ? Time.zone.parse(value.to_s) : Time.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def extract_patient_ids(record)
    PatientIds.new(
      national_id: record.dig(:otherPersonInformation, :nationalID),
      ichis_id:    record.dig(:otherPersonInformation, :ichisID),
      birth_id:    record.dig(:otherPersonInformation, :birthID)
    )
  end

  def initialize_managers
    {
      identity_manager:       PatientRecordService::PatientIdentityManager.new,
      guardian_manager:       PatientRecordService::GuardianManager.new,
      enrollment_manager:     PatientRecordService::PatientEnrollmentManager.new,
      lab_data_manager:       PatientRecordService::LabDataManager.new,
      vaccine_manager:        PatientRecordService::VaccineManager.new,
      sms_manager:            PatientRecordService::SmsManager.new,
      medication_order_saver: PatientRecordService::MedicationOrderSaver.new,
      dispensation_saver:     PatientRecordService::DispensationSaver.new,
      observation_saver:      PatientRecordService::ObservationSaver.new,
      void_encounters:        PatientRecordService::VoidEncounters.new,
      merge_patients_manager: PatientRecordService::MergePatientManager.new,
      void_drug_orders:       PatientRecordService::VoidDrugOrders.new,
      void_patient:           PatientRecordService::VoidPatient.new
    }
  end

  def execute_patient_operations(patient_id, record, managers)
    {
      update_person_info:     run_if(person_information_edit?(record)) { managers[:identity_manager].update_person_information(patient_id, record) },
      void_legacy_dde_ids:    run_if(legacy_dde_identifier_void_pending?(record)) {
        managers[:identity_manager].void_legacy_dde_identifiers(patient_id, record)
      },
      merge_patients:         run_if(merge_requested?(record)) { managers[:merge_patients_manager].merge_patients(patient_id, record) },
      manage_guardian:        run_if(guardian_work_pending?(record)) { managers[:guardian_manager].manage_guardian(patient_id, record) },
      create_relationship:    run_if(relationships_pending?(record)) { managers[:guardian_manager].create_relationship(record) },
      enroll_program:         run_if(enrollments_pending?(record)) { managers[:enrollment_manager].enroll_program(patient_id, record) },
      save_lab_orders_data:   run_if(lab_orders_pending?(record)) { managers[:lab_data_manager].save_lab_orders_data(patient_id, record) },
      save_lab_results_data:  run_if(lab_results_pending?(record)) { managers[:lab_data_manager].save_lab_results_data(patient_id, record) },
      void_lab_order:         run_if(lab_order_voids_pending?(record)) { managers[:lab_data_manager].void_lab_order(patient_id, record) },
      save_vaccines:          run_if(vaccine_orders_pending?(record)) { managers[:vaccine_manager].save_vaccines(patient_id, record) },
      send_sms:               run_if(sms_pending?(record)) { managers[:sms_manager].send_sms(patient_id, record) },
      void_vaccine:           run_if(vaccine_voids_pending?(record)) { managers[:vaccine_manager].void_vaccine(patient_id, record) },
      save_medication_order:  run_if(medication_orders_pending?(record)) { managers[:medication_order_saver].save_medication_order(patient_id, record) },
      create_ncd_identifier:  run_if(ncd_identifier_pending?(record)) { managers[:identity_manager].create_ncd_identifier(patient_id, record) },
      save_dispensation_data: run_if(dispensations_pending?(record)) { managers[:medication_order_saver].save_dispensation_data(patient_id, record) },
      void_drug_orders:       run_if(drug_order_voids_pending?(record)) { managers[:void_drug_orders].void_drug_orders(patient_id, record) },
      save_all_observations:  run_if(observations_pending?(record)) { managers[:observation_saver].save_all_observations(patient_id, record) },
      void_encounters:        run_if(encounter_voids_pending?(record)) { managers[:void_encounters].void_encounters(record) },
      void_patient:           run_if(patient_void_pending?(record)) { managers[:void_patient].void_patient(patient_id, record) }
    }
  end

  def build_and_save_patient_record(patient_id, patient_data, operation_results, overall_sync_status, created_lab_orders: [], couch_base: nil)
    restore_trimmed_history!(patient_data, couch_base)
    patient          = BuildPatientRecordService.find_patient(patient_id)
    person           = patient&.person
    latest_encounter = BuildPatientRecordService.find_latest_encounter(patient_id)
    changed_operation_results = changed_operations(operation_results)
    identifiers_by_type = BuildPatientRecordService.patient_identifiers_by_type(patient)

    patient_data[:encounter_datetime]    = latest_encounter&.encounter_datetime
    patient_data[:location_id]           = latest_encounter.location_id if latest_encounter&.location_id.present?
    patient_data[:ID]                    = BuildPatientRecordService.patient_identifier_from_map(identifiers_by_type, 3, patient_id)
    patient_data[:legacyDdeID]           = BuildPatientRecordService.patient_identifier_from_map(identifiers_by_type, 2, patient_id)
    patient_data[:legacyDdeIDs]          = BuildPatientRecordService.patient_identifier_values_from_map(identifiers_by_type, 2)
    patient_data[:nationalID]            = BuildPatientRecordService.patient_identifier_from_map(identifiers_by_type, 28, patient_id)
    patient_data[:patientID]             = patient_id
    patient_data[:NcdID]                 = BuildPatientRecordService.patient_identifier_from_map(identifiers_by_type, 31, patient_id)
    patient_data[:patient_identifiers]   = patient.patient_identifiers.as_json
    patient_data[:sync_status]           = overall_sync_status
    patient_data[:otherPersonInformation] = BuildPatientRecordService.build_other_person_info
    patient_data[:visits]                = BuildPatientRecordService.safe_get_visits(patient) if refresh_visit_dates?(patient_data, changed_operation_results)

    # Keep the incoming activePrograms unless enrollment changed or the caller
    # sent no activePrograms. Fetching it on every save turns lab-only saves into
    # unnecessary PatientProgram queries and JSON serialization.
    enroll_program_changed = changed_operation_results[:enroll_program]&.success?
    if enroll_program_changed || Array(record_value(patient_data, :activePrograms)).blank?
      patient_data[:activePrograms] = BuildPatientRecordService.fetch_active_programs(patient.patient_id)
    end

    allowed_encounter_types = []

    changed_operation_results.each do |key, result|
      next unless result.success?

      case key
      when :update_person_info
        name    = person&.names&.first
        address = person&.addresses&.first
        patient_data[:personInformation] = BuildPatientRecordService.build(person, name, address, patient)

      when :void_legacy_dde_ids
        patient_data[:voidLegacyDdeIdentifiers] = []

      when :manage_guardian, :create_relationship
        patient_data[:guardianInformation] = BuildPatientRecordService.build_guardian_data(patient_id)
        patient_data[:relationships]       = []

      when :enroll_program
        patient_data[:activePrograms] = BuildPatientRecordService.fetch_active_programs(patient_id)

      when :save_lab_orders_data
        # Rebuilding the entire lab order history here costs ~25 queries per
        # historical order and grows with patient history, so merge just the
        # newly created orders into the record instead. A delayed
        # RebuildPatientLabDataJob trues up the CouchDB copy from MySQL. Falls
        # back to the full rebuild when the created-order capture is
        # incomplete. Results/voids (below) still rebuild because their
        # changes touch existing saved orders.
        if created_lab_orders.present?
          merge_created_lab_orders!(patient_data, created_lab_orders)
          enqueue_lab_orders_couchdb_true_up(patient_id)
        else
          patient_data[:labOrders] = BuildPatientRecordService.build_lab_orders_data(patient_id)
        end
        allowed_encounter_types << get_encounter_id('LAB ORDERS')
        allowed_encounter_types << get_encounter_id('LAB RESULTS')

      when :save_lab_results_data, :void_lab_order
        patient_data[:labOrders] = BuildPatientRecordService.build_lab_orders_data(patient_id)
        allowed_encounter_types << get_encounter_id('LAB ORDERS')
        allowed_encounter_types << get_encounter_id('LAB RESULTS')

      when :save_vaccines, :void_vaccine
        patient_data[:vaccineAdministration] = BuildPatientRecordService.build_vaccine_administration_data(patient_id)
        patient_data[:MedicationOrder]       = BuildPatientRecordService.build_medication_data(patient_id)
        allowed_encounter_types << get_encounter_id('TREATMENT')

      when :save_medication_order, :save_dispensation_data, :void_drug_orders
        patient_data[:MedicationOrder] = BuildPatientRecordService.build_medication_data(patient_id)
        allowed_encounter_types << get_encounter_id('TREATMENT')

      when :create_ncd_identifier
        patient_data[:NcdID] = BuildPatientRecordService.patient_identifier_from_map(identifiers_by_type, 31, patient_id)

      when :void_encounters
        voided_encounter_ids = patient_data.dig(:void_encounters)&.map { |ve| ve[:id] }&.compact || []

        if voided_encounter_ids.any?
          voided_encounter_types = Encounter.unscoped
                                            .where(encounter_id: voided_encounter_ids)
                                            .pluck(:encounter_type)
                                            .uniq
          allowed_encounter_types.concat(voided_encounter_types)
        end

        patient_data[:void_encounters] = []

      when :save_all_observations
        unsaved_encounter_types = Array(record_value(patient_data, :observations))
                                    .select { |e| record_value(e, :status) == "unsaved" }
                                    .map    { |e| record_value(e, :encounter_type) }
                                    .compact
                                    .uniq
        allowed_encounter_types.concat(unsaved_encounter_types)
      end
    end

    rebuild_all_observations(patient_id, patient_data, allowed_encounter_types)

    # Attach errors from all operations — keyed by operation name
    patient_data[:operation_errors] = operation_results
      .reject        { |_k, r| r.errors.empty? }
      .transform_values { |r| r.errors }
      .as_json

    strip_derived_patient_fields!(patient_data)
    clear_processed_pending_fields!(patient_data)
    PatientRecordSearchFields.normalize!(patient_data)
    patient_data.as_json
  end

  # The authoritative full record used to re-attach the read-only history the
  # lean online payload omits. Prefers the current CouchDB doc (a single fast
  # fetch); falls back to a MySQL rebuild only when the doc is absent (e.g. a
  # brand-new patient, where the rebuild is cheap). Returns nil on the
  # listener/offline ingest path (skip_couchdb_sync? — the record already
  # carries the full doc) or when CouchDB is not configured, in which case
  # restore_trimmed_history! is a no-op and the client payload is used as-is.
  def resolve_history_base(patient_id, record)
    return nil unless couchdb_configured? && !skip_couchdb_sync?

    doc_id = record_value(record, :ID).to_s
    base   = doc_id.present? ? fetch_couchdb_doc('patients_records', doc_id) : nil
    base ||= (patient_id ? BuildPatientRecordService.build_patient_record(patient_id) : nil)
    base
  rescue StandardError => e
    Rails.logger.warn("[SavePatientRecord] could not resolve history base for #{record_value(record, :ID)}: #{e.class}: #{e.message}")
    nil
  end

  # Builds the response/CouchDB doc for a patient that was just voided. Reuses
  # the last-known-good CouchDB doc (or the incoming record, when no doc is
  # configured/available) rather than rebuilding from MySQL, since the patient
  # row and its dependents are voided by this point.
  #
  # We don't want to keep voided patients' documents in CouchDB at all, so the
  # doc is deleted outright rather than upserted with a `voided` flag. Deletion
  # replicates like any other change, so every device eventually drops its copy
  # too. If the delete itself fails (e.g. a transient CouchDB outage), we fall
  # back to upserting with `voided: true` so the doc is at least excluded from
  # search (see NOT_VOIDED_SELECTOR on the client) instead of staying fully
  # visible with no signal at all.
  def finalize_voided_patient_record(patient_id, record, operation_results, overall_sync_status)
    base = resolve_history_base(patient_id, record) || record
    patient_record = base.as_json.with_indifferent_access

    patient_record['patientID']    = patient_id
    patient_record['sync_status']  = overall_sync_status
    patient_record['void_patient'] = nil
    patient_record['voided']       = true
    patient_record['operation_errors'] = operation_results
      .reject           { |_k, r| r.errors.empty? }
      .transform_values  { |r| r.errors }
      .as_json

    if couchdb_configured?
      patient_record['_id'] = patient_record['ID']

      begin
        delete_from_couchdb('patients_records', patient_record['ID'].to_s)
        # Tells the CouchDB changes listener the document is gone on purpose,
        # so it skips trying to fetch and re-mark a now-nonexistent doc.
        patient_record['deleted_from_couchdb'] = true
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
        Rails.logger.warn("CouchDB connection error while deleting voided patient #{patient_record['ID']}: #{e.class}: #{e.message}")
        sync_voided_patient_fallback(patient_record)
      rescue StandardError => e
        Rails.logger.error("CouchDB delete failed for voided patient #{patient_record['ID']}: #{e.class}: #{e.message}")
        sync_voided_patient_fallback(patient_record)
      end
    end

    patient_record.as_json
  end

  def sync_voided_patient_fallback(patient_record)
    sync_to_couchdb(patient_record, 'patients_records', patient_record['ID'].to_s)
  rescue StandardError => e
    Rails.logger.error("CouchDB fallback sync failed for voided patient #{patient_record['ID']}: #{e.class}: #{e.message}")
  end

  # Re-attach read-only history the online client stripped from its payload, so
  # the saved CouchDB doc and the response still carry the full record while the
  # request stays small. No-op when no base is supplied (listener/offline ingest
  # already carries the full doc) or when the client already sent the section
  # (full/legacy payloads). Sections the client did send — this visit's writes —
  # are left untouched, and the existing per-operation rebuild logic still
  # refreshes changed sections from MySQL over the top.
  def restore_trimmed_history!(patient_data, couch_base)
    return patient_data if couch_base.blank?

    restore_observation_history!(patient_data, couch_base)
    restore_lab_order_history!(patient_data, couch_base)
    restore_medication_order_history!(patient_data, couch_base)
    restore_active_programs_history!(patient_data, couch_base)
    restore_guardian_history!(patient_data, couch_base)
    restore_vaccine_obs_history!(patient_data, couch_base)

    # Whole read-only sections the client may omit and the backend does not
    # unconditionally rebuild: art_summary (never), visits (only conditionally),
    # personInformation (only on edit). Restore from the base when the client
    # omitted them. Preserve empty values ([]/{}) too, so a section the base
    # defined never comes back absent. (patient_identifiers is always rebuilt
    # below, so it needs no restore.)
    %i[art_summary visits personInformation].each do |key|
      next if record_value(patient_data, key).present?

      base_value = record_value(couch_base, key)
      patient_data[key] = base_value unless base_value.nil?
    end

    patient_data
  end

  # Merge the base's observation encounters (keyed by encounter_type) underneath
  # the client's. The client's encounters win on a type collision, and
  # rebuild_all_observations later refreshes the changed types from MySQL, so no
  # history is lost — untouched historical encounter types simply carry through.
  def restore_observation_history!(patient_data, couch_base)
    base_obs = Array(record_value(couch_base, :observations))
    return if base_obs.empty?

    merged_by_type = {}
    base_obs.each do |group|
      type = record_value(group, :encounter_type)
      merged_by_type[type] = group if type.present?
    end

    typeless_client_groups = []
    Array(record_value(patient_data, :observations)).each do |group|
      type = record_value(group, :encounter_type)
      if type.present?
        merged_by_type[type] = group
      else
        typeless_client_groups << group
      end
    end

    patient_data[:observations] = merged_by_type.values + typeless_client_groups
  end

  # Restore labOrders.saved (historical orders) from the base when the client
  # omitted it. Lab writes (unsaved/results/voided) the client did send still
  # trigger the full labOrders rebuild from MySQL in build_and_save_patient_record.
  def restore_lab_order_history!(patient_data, couch_base)
    base_lab = record_value(couch_base, :labOrders)
    return if base_lab.blank?

    client_lab = record_value(patient_data, :labOrders)
    if client_lab.blank?
      patient_data[:labOrders] = base_lab
      return
    end

    return if record_value(client_lab, :saved).present?

    base_saved = record_value(base_lab, :saved)
    # Restore even an empty [] so labOrders.saved never comes back absent
    # (the frontend maps over it).
    assign_subkey(client_lab, :saved, base_saved) unless base_saved.nil?
  end

  # Restore MedicationOrder.saved (order history) from the base, keeping any
  # saved order the client sent that carries a dispensation (dispensations_pending?
  # / save_dispensation_data read saved[].dispensation). Client entries win on an
  # order_id collision. When a medication/dispensation/void op runs, build_and_save
  # rebuilds MedicationOrder fully from MySQL over this, so it is only load-bearing
  # for the no-med-activity carry-through case.
  def restore_medication_order_history!(patient_data, couch_base)
    base_med   = record_value(couch_base, :MedicationOrder)
    base_saved = Array(record_value(base_med, :saved))
    return if base_saved.empty?

    client_med = record_value(patient_data, :MedicationOrder)
    if client_med.blank?
      patient_data[:MedicationOrder] = base_med
      return
    end

    client_saved = Array(record_value(client_med, :saved))
    client_ids   = client_saved.map { |order| record_value(order, :order_id) }.compact
    merged_saved = base_saved.reject { |order| client_ids.include?(record_value(order, :order_id)) } + client_saved

    assign_subkey(client_med, :saved, merged_saved)
  end

  # Restore saved-program history from the base. The client sends only new
  # enrollments (status "unsaved"); union the base's programs underneath, keyed
  # by patient_program_id so nothing duplicates. When enrollment changes,
  # build_and_save refetches activePrograms fully from MySQL over this.
  def restore_active_programs_history!(patient_data, couch_base)
    base_programs = Array(record_value(couch_base, :activePrograms))
    return if base_programs.empty?

    client_programs = Array(record_value(patient_data, :activePrograms))
    client_ids      = client_programs.map { |program| record_value(program, :patient_program_id) }.compact
    merged = base_programs.reject { |program| client_ids.include?(record_value(program, :patient_program_id)) } + client_programs

    patient_data[:activePrograms] = merged
  end

  # Restore guardianInformation.saved (guardian history) from the base when the
  # client omitted it. manage_guardian only reads .unsaved, which the client
  # still sends; a guardian op still rebuilds the section fully from MySQL.
  def restore_guardian_history!(patient_data, couch_base)
    base_guardian = record_value(couch_base, :guardianInformation)
    return if base_guardian.blank?

    client_guardian = record_value(patient_data, :guardianInformation)
    if client_guardian.blank?
      patient_data[:guardianInformation] = base_guardian
      return
    end

    return if record_value(client_guardian, :saved).present?

    base_saved = record_value(base_guardian, :saved)
    assign_subkey(client_guardian, :saved, base_saved) unless base_saved.nil?
  end

  # Restore vaccineAdministration.obs (vaccine obs history) from the base when
  # the client omitted it. The client keeps obs whenever there is a vaccine
  # write (save_vaccines reads it), so this only fills the no-vaccine-write case.
  def restore_vaccine_obs_history!(patient_data, couch_base)
    base_vaccine = record_value(couch_base, :vaccineAdministration)
    return if base_vaccine.blank?

    client_vaccine = record_value(patient_data, :vaccineAdministration)
    if client_vaccine.blank?
      patient_data[:vaccineAdministration] = base_vaccine
      return
    end

    return if record_value(client_vaccine, :obs).present?

    base_obs = record_value(base_vaccine, :obs)
    assign_subkey(client_vaccine, :obs, base_obs) unless base_obs.nil?
  end

  # Set a sub-key on a hash that may use either symbol or string keys, matching
  # whichever form the container already uses (JSON-sourced hashes use strings).
  def assign_subkey(container, key, value)
    return unless container.respond_to?(:[]=)

    keys       = container.respond_to?(:keys) ? container.keys : []
    has_symbol = keys.any? { |k| k.is_a?(Symbol) }
    has_string = keys.any? { |k| k.is_a?(String) }
    # Default to a string key (JSON/CouchDB convention) unless the container is
    # clearly symbol-keyed; only match symbol when there are symbol keys and no
    # string keys. (ActionController::Parameters is indifferent either way.)
    use_string = has_string || !has_symbol
    container[use_string ? key.to_s : key] = value
  end

  def get_encounter_id(encounter_type)
    @encounter_type_ids_by_name ||= {}
    return @encounter_type_ids_by_name[encounter_type] if @encounter_type_ids_by_name.key?(encounter_type)

    @encounter_type_ids_by_name[encounter_type] = EncounterType.find_by_name(encounter_type)&.encounter_type_id
  end

  def changed_operations(operation_results)
    operation_results.select { |_key, result| operation_changed?(result) }
  end

  def changed_operation_keys(operation_results)
    changed_operations(operation_results).keys
  end

  def operation_changed?(result)
    return result.changed? if result.respond_to?(:changed?)

    result.success?
  end

  def refresh_visit_dates?(patient_data, changed_operation_results)
    return true if record_value(patient_data, :saveStatusPersonInformation) == 'pending'

    visit_affecting_operations = changed_operation_results.keys - %i[
      create_ncd_identifier
      create_relationship
      manage_guardian
      save_lab_orders_data
      save_lab_results_data
      send_sms
      update_person_info
      void_lab_order
    ]

    visit_affecting_operations.any?
  end

  def rebuild_all_observations(patient_id, patient_data, allowed_encounter_types)
    allowed_encounter_types = allowed_encounter_types.compact.uniq
    return if allowed_encounter_types.empty?

    refreshed_type_keys = allowed_encounter_types.map(&:to_s)
    original_observations_map = Array(record_value(patient_data, :observations))
                                  .each_with_object({}) do |obs, hash|
                                    encounter_type = record_value(obs, :encounter_type)
                                    next if encounter_type.blank?
                                    next if refreshed_type_keys.include?(encounter_type.to_s)

                                    hash[encounter_type.to_s] = obs
                                  end

    new_observations = BuildPatientRecordService.build_all_observations(patient_id, allowed_encounter_types)

    updated_observations_hash = original_observations_map.merge(
      new_observations.index_by { |obs| record_value(obs, :encounter_type).to_s }
    )

    patient_data[:observations] = updated_observations_hash.values.as_json
  end

  def record_value(container, key)
    return nil if container.nil? || !container.respond_to?(:[])

    container[key] || container[key.to_s]
  rescue TypeError
    nil
  end

  # Append the orders created during this save to labOrders.saved, replacing
  # any stale copies of the same order the client may have sent.
  def merge_created_lab_orders!(patient_data, created_lab_orders)
    lab_orders = record_value(patient_data, :labOrders)
    unless lab_orders.respond_to?(:[]=)
      lab_orders = {}
      patient_data[:labOrders] = lab_orders
    end

    created_ids = created_lab_orders.map { |order| record_value(order, :order_id) }.compact
    existing = Array.wrap(record_value(lab_orders, :saved)).reject do |order|
      created_ids.include?(record_value(order, :order_id))
    end

    saved_key = lab_orders.respond_to?(:key?) && lab_orders.key?('saved') ? 'saved' : :saved
    lab_orders[saved_key] = existing + created_lab_orders
  end

  # The synchronous full labOrders rebuild used to make the CouchDB copy
  # authoritative on every save. Preserve that invariant off-request: the
  # delay lets create_patient_record finish its own CouchDB sync first.
  def enqueue_lab_orders_couchdb_true_up(patient_id)
    RebuildPatientLabDataJob.set(wait: 30.seconds).perform_later(
      patient_id,
      trigger: 'save_patient_record_lab_orders_true_up',
      metadata: {}
    )
  rescue StandardError => e
    Rails.logger.warn("Failed to enqueue labOrders CouchDB true-up for patient #{patient_id}: #{e.class}: #{e.message}")
  end

  def ensure_primary_identifier_persisted!(patient_id, patient_record)
    identifier = patient_record.with_indifferent_access[:ID].to_s.strip
    raise "Primary identifier missing for patient #{patient_id}" if identifier.blank?

    saved_identifier = PatientIdentifier.unscoped.find_by(
      patient_id: patient_id,
      identifier: identifier,
      identifier_type: 3,
      voided: 0
    )

    return if saved_identifier.present?

    raise "Primary identifier #{identifier} not found in MySQL for patient #{patient_id}"
  end

  def strip_derived_patient_fields!(record)
    return record unless record.respond_to?(:delete)

    record.delete(:vaccineSchedule)
    record.delete('vaccineSchedule')
    record
  end

  def clear_processed_pending_fields!(record)
    return record unless record.respond_to?(:delete)

    record.delete(:art_orders_pending)
    record.delete('art_orders_pending')
    record.delete(:art_dispensation_pending)
    record.delete('art_dispensation_pending')
    record.delete(:voidedDrugOders)
    record.delete('voidedDrugOders')
    record
  end

  def enqueue_post_save_side_effects(patient_id, record, operation_results)
    keys = changed_operation_keys(operation_results)
    return if keys.empty?

    PatientRecordPostSaveSideEffectsJob.perform_later(
      patient_id,
      post_save_side_effect_payload(record),
      keys.map(&:to_s)
    )
  rescue StandardError => e
    Rails.logger.error(
      "Failed to enqueue patient-record post-save side effects for patient #{patient_id}: #{e.class}: #{e.message}"
    )
  end

  def should_top_up_dde_ids_after_save?(record)
    record_value(record, :saveStatusPersonInformation).to_s == 'pending' &&
      record_value(record, :ID).to_s.strip.present?
  end

  def enqueue_dde_id_top_up(patient_record, source_record)
    location_id = record_value(source_record, :location_id).presence ||
                  record_value(patient_record, :location_id).presence ||
                  User.current&.location_id
    identifier = record_value(patient_record, :ID).to_s.strip
    return if location_id.blank? || identifier.blank?

    DdeIdPoolService.new.consume!(
      npid: identifier,
      location_id: location_id,
      patient_id: record_value(patient_record, :patientID)
    )

    job_id = Sync::DdeIdsSyncJob.perform_async(100, location_id.to_s)
    Rails.logger.info(
      "Queued DDE ID top-up job #{job_id} for location #{location_id} after saving patient record #{identifier}"
    )
  rescue StandardError => e
    Rails.logger.warn(
      "Failed to enqueue DDE ID top-up after saving patient record #{record_value(patient_record, :ID)}: #{e.class}: #{e.message}"
    )
  end

  def post_save_side_effect_payload(record)
    {
      'program_id' => record_value(record, :program_id),
      'location_id' => record_value(record, :location_id).presence || User.current&.location_id,
      'encounter_datetime' => record_value(record, :encounter_datetime),
      'date_enrolled' => record_value(record, :date_enrolled),
      'activePrograms' => serializable_value(record_value(record, :activePrograms)),
      'NcdID' => record_value(record, :NcdID),
      'TEI' => record_value(record, :TEI),
      'otherPersonInformation' => serializable_value(record_value(record, :otherPersonInformation) || {}),
      'send_ichis_enrolled_in_care_event_id' => record_value(record, :send_ichis_enrolled_in_care_event_id),
      'ichisEventIds' => record_value(record, :ichisEventIds) || record_value(record, :ichis_event_ids)
    }.compact
  end

  def serializable_value(value)
    value.respond_to?(:as_json) ? value.as_json : value
  end

  def run_if(condition)
    return PatientRecordService::OperationResult.ok unless condition

    yield
  end

  def person_information_edit?(record)
    record_value(record, :personInformation).present? && record_value(record, :saveStatusPersonInformation) == 'edit'
  end

  def legacy_dde_identifier_void_pending?(record)
    Array.wrap(record_value(record, :voidLegacyDdeIdentifiers)).any? { |identifier| identifier.to_s.strip.present? }
  end

  def merge_requested?(record)
    record_value(record_value(record, :otherPersonInformation) || {}, :secondaryPatientID).present?
  end

  def guardian_work_pending?(record)
    %w[pending edit].include?(record_value(record, :saveStatusGuardianInformation).to_s) ||
      record_value(record, :nextOfKinInformation).present?
  end

  def relationships_pending?(record)
    Array.wrap(record_value(record, :relationships)).any?
  end

  def enrollments_pending?(record)
    Array.wrap(record_value(record, :activePrograms)).any? do |item|
      item.present? && record_value(item, :status) == 'unsaved'
    end
  end

  def lab_orders_pending?(record)
    Array.wrap(record_value(record_value(record, :labOrders) || {}, :unsaved)).any?
  end

  def lab_results_pending?(record)
    Array.wrap(record_value(record_value(record, :labOrders) || {}, :results)).flatten(1).compact.any?
  end

  def lab_order_voids_pending?(record)
    Array.wrap(record_value(record_value(record, :labOrders) || {}, :voided)).any?
  end

  def vaccine_orders_pending?(record)
    Array.wrap(record_value(record_value(record, :vaccineAdministration) || {}, :orders)).any?
  end

  def vaccine_voids_pending?(record)
    Array.wrap(record_value(record_value(record, :vaccineAdministration) || {}, :voided)).any?
  end

  def sms_pending?(record)
    sms = record_value(record, :sms) || {}
    record_value(sms, :appointment_date).present? && Array.wrap(record_value(sms, :cell_phone)).any?
  end

  def medication_orders_pending?(record)
    medication_order = record_value(record, :MedicationOrder) || {}
    Array.wrap(record_value(medication_order, :unsaved)).any? ||
      Array.wrap(record_value(record, :art_orders_pending)).any?
  end

  def ncd_identifier_pending?(record)
    ncd_id = record_value(record, :NcdID).to_s.strip
    ncd_id == '-' ||
      ncd_id.casecmp?('PENDING') ||
      ActiveModel::Type::Boolean.new.cast(record_value(record, :needs_ncd_id)) ||
      record_value(record, :unsavedNcdID).present?
  end

  def dispensations_pending?(record)
    medication_order = record_value(record, :MedicationOrder) || {}
    Array.wrap(record_value(medication_order, :saved)).any? do |order|
      record_value(order, :dispensation).present?
    end || Array.wrap(record_value(record, :art_dispensation_pending)).any?
  end

  def drug_order_voids_pending?(record)
    voided_drug_orders = record_value(record, :voidedDrugOders) || {}
    Array.wrap(record_value(voided_drug_orders, :unsaved)).any?
  end

  def observations_pending?(record)
    Array.wrap(record_value(record, :observations)).any? do |item|
      item.present? && record_value(item, :status) == 'unsaved' && record_value(item, :obs).present?
    end
  end

  def encounter_voids_pending?(record)
    Array.wrap(record_value(record, :void_encounters)).any?
  end

  def patient_void_pending?(record)
    record_value(record_value(record, :void_patient) || {}, :reason).to_s.strip.present?
  end
end
