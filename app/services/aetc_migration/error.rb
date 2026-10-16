# frozen_string_literal: true

module AetcMigration
  # Raised for problems the person running the migration can fix (bad input, missing schema, ...).
  # The rake tasks show the message without a backtrace.
  class Error < StandardError; end
end
