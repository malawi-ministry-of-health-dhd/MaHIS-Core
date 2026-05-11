# frozen_string_literal: true

# Subscribe to lab events from the his_emr_api_lab gem
# When lab data changes, automatically enqueue jobs to rebuild patient records
Rails.application.config.after_initialize do
  Rails.logger.info('Initializing lab event subscribers...')

  # Subscribe to results created/saved events
  ActiveSupport::Notifications.subscribe('lab.results_created') do |name, _start, _finish, _id, payload|
    Rails.logger.debug("Lab event received: #{name} - Patient: #{payload[:patient_id]}")

    RebuildPatientLabDataJob.perform_later(
      payload[:patient_id],
      trigger: 'results_created',
      metadata: {
        order_id: payload[:order_id],
        result_id: payload[:result_id],
        test_id: payload[:test_id],
        event_time: payload[:timestamp]
      }
    )
  rescue StandardError => e
    Rails.logger.error("Failed to enqueue RebuildPatientLabDataJob for results_created: #{e.message}")
  end

  ActiveSupport::Notifications.subscribe('lab.results_saved') do |name, _start, _finish, _id, payload|
    Rails.logger.debug("Lab event received: #{name} - Patient: #{payload[:patient_id]}")

    RebuildPatientLabDataJob.perform_later(
      payload[:patient_id],
      trigger: 'results_saved',
      metadata: {
        order_id: payload[:order_id],
        result_id: payload[:result_id],
        encounter_id: payload[:encounter_id],
        event_time: payload[:timestamp]
      }
    )
  rescue StandardError => e
    Rails.logger.error("Failed to enqueue RebuildPatientLabDataJob for results_saved: #{e.message}")
  end

  # Subscribe to order status changed event
  ActiveSupport::Notifications.subscribe('lab.order_status_changed') do |name, _start, _finish, _id, payload|
    Rails.logger.debug("Lab event received: #{name} - Patient: #{payload[:patient_id]} - Status: #{payload[:new_status]}")

    RebuildPatientLabDataJob.perform_later(
      payload[:patient_id],
      trigger: 'order_status_changed',
      metadata: {
        order_id: payload[:order_id],
        new_status: payload[:new_status],
        tracking_number: payload[:tracking_number],
        event_time: payload[:timestamp]
      }
    )
  rescue StandardError => e
    Rails.logger.error("Failed to enqueue RebuildPatientLabDataJob for order_status_changed: #{e.message}")
  end

  # Subscribe to order created event
  ActiveSupport::Notifications.subscribe('lab.order_created') do |name, _start, _finish, _id, payload|
    Rails.logger.debug("Lab event received: #{name} - Patient: #{payload[:patient_id]}")

    RebuildPatientLabDataJob.perform_later(
      payload[:patient_id],
      trigger: 'order_created',
      metadata: {
        order_id: payload[:order_id],
        accession_number: payload[:accession_number],
        event_time: payload[:timestamp]
      }
    )
  rescue StandardError => e
    Rails.logger.error("Failed to enqueue RebuildPatientLabDataJob for order_created: #{e.message}")
  end

  # Subscribe to order voided event
  ActiveSupport::Notifications.subscribe('lab.order_voided') do |name, _start, _finish, _id, payload|
    Rails.logger.debug("Lab event received: #{name} - Patient: #{payload[:patient_id]}")

    RebuildPatientLabDataJob.perform_later(
      payload[:patient_id],
      trigger: 'order_voided',
      metadata: {
        order_id: payload[:order_id],
        event_time: payload[:timestamp]
      }
    )
  rescue StandardError => e
    Rails.logger.error("Failed to enqueue RebuildPatientLabDataJob for order_voided: #{e.message}")
  end

  Rails.logger.info('Lab event subscribers initialized successfully')
  Rails.logger.info('Subscribed to events: lab.results_created, lab.results_saved, lab.order_status_changed, lab.order_created, lab.order_voided')
end
