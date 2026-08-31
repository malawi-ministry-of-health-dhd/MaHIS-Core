# frozen_string_literal: true

# Raised when a client has exceeded a rate limit and must back off. Carries the
# number of seconds the client should wait so the controller can set Retry-After.
class TooManyRequestsError < ApplicationError
  attr_reader :retry_after

  def initialize(message = 'Too many requests', retry_after: nil)
    super(message)
    @retry_after = retry_after
  end
end
