# frozen_string_literal: true

# this job is used to clear notifications after a certain period of time has elapsed
class NotificationClearJob < ApplicationJob
  queue_as :default

  def perform
    lab = User.find_by(username: 'lab_daemon')
    expired_alert_ids = NotificationAlert.unscoped
                                         .where(alert_read: 0)
                                         .where('date_to_expire < ?', Time.current)
                                         .pluck(:alert_id)
    return if expired_alert_ids.empty?

    alert_updates = { alert_read: true, date_changed: Time.current }
    alert_updates[:changed_by] = lab.user_id if lab

    NotificationAlert.unscoped.where(alert_id: expired_alert_ids).update_all(alert_updates)
    NotificationAlertRecipient.unscoped.where(alert_id: expired_alert_ids).update_all(cleared: true, alert_read: true)
  end
end
