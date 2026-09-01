# frozen_string_literal: true

# Nightly sweep that closes accounts whose period has ended.
#
# The login check in UserService.enforce_account_period! is authoritative, but it
# only fires when somebody actually tries to log in. A student or intern who
# simply stops coming would otherwise keep showing as active in User Management
# indefinitely, and any token issued before their end date would keep working.
# This sweep makes the list tell the truth.
class DeactivateExpiredAccountsJob < ApplicationJob
  queue_as :default

  def perform(*_args)
    deactivated = UserService.deactivate_expired_accounts!

    Rails.logger.info("[AccountExpiry] Nightly sweep deactivated #{deactivated} expired account(s)")
    deactivated
  end
end
