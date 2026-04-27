# frozen_string_literal: true

minimum_date = Date.parse('2026-01-01')
sixty_days_ago = Date.today - 60.days
start_date = [sixty_days_ago, minimum_date].max.to_s

Lab::Lims::Worker.start(start_date: start_date)
