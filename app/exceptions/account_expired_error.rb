# frozen_string_literal: true

# Raised when a supervised user's account period has ended.
#
# Deliberately raised only AFTER the password has been verified: telling an
# unauthenticated caller that an account exists but has expired would leak which
# usernames are real, which is exactly what the generic "Invalid user or
# password" response elsewhere in the login flow exists to prevent.
class AccountExpiredError < ApplicationError
  attr_reader :expired_on

  def initialize(message = 'Your account period has ended. Please contact your supervisor.', expired_on: nil)
    super(message)
    @expired_on = expired_on
  end
end
