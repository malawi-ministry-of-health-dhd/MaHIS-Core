# frozen_string_literal: true

# The unique index added in AddLabIdentifiersToNotificationAlerts was meant to be scoped
# to unread alerts via its `where:` clause, but MySQL doesn't support partial/filtered
# unique indexes, so Rails silently drops that condition and the index ends up covering
# every row regardless of alert_read. As a result, once a lab alert for a given
# test/order/specimen combo was read (alert_read = 1), no new alert could ever be created
# for that same combo again - Lab::NotificationService#create_notification would hit
# ActiveRecord::RecordNotUnique on insert, then fail to find the (already read) existing
# row because NotificationAlert's default_scope only looks at alert_read = 0, silently
# dropping the notification for any new/updated result until NotificationClearJob expired
# the stale row (up to 7 days later).
#
# MySQL's workaround for conditional uniqueness is a generated column that evaluates to
# NULL for rows that shouldn't be constrained (unique indexes never conflict on NULL), with
# the unique index placed on that generated column instead of the raw columns.
class ScopeNotificationAlertLabUniquenessToUnread < ActiveRecord::Migration[8.1]
  def up
    remove_index :notification_alert, name: 'idx_notification_alert_lab_unique', if_exists: true

    unless column_exists?(:notification_alert, :unread_lab_alert_key)
      add_column :notification_alert, :unread_lab_alert_key, :virtual,
                 type: :string, limit: 191,
                 as: "(CASE WHEN alert_read = 0 AND test_type_id IS NOT NULL AND order_id IS NOT NULL " \
                     "AND specimen_id IS NOT NULL THEN CONCAT(test_type_id, '-', order_id, '-', specimen_id) END)",
                 stored: true
    end

    add_index :notification_alert, :unread_lab_alert_key,
              unique: true,
              name: 'idx_notification_alert_lab_unique_unread'
  end

  def down
    remove_index :notification_alert, name: 'idx_notification_alert_lab_unique_unread', if_exists: true
    remove_column :notification_alert, :unread_lab_alert_key if column_exists?(:notification_alert,
                                                                               :unread_lab_alert_key)

    add_index :notification_alert,
              %i[test_type_id order_id specimen_id],
              unique: true,
              name: 'idx_notification_alert_lab_unique',
              where: 'test_type_id IS NOT NULL AND order_id IS NOT NULL AND specimen_id IS NOT NULL'
  end
end
