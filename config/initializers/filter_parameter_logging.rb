# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Configure sensitive parameters which will be filtered from the log file.
# `audio` carries a dictated clinical note. It is patient data and must never
# reach the log, even truncated.
Rails.application.config.filter_parameters += %i[password audio]
