# frozen_string_literal: true

minimum_date = Date.parse('2026-01-01')
# To avoid processing an excessive amount of historical data, we limit the start date to 120 days ago or the minimum date, whichever is later.
# 120 days because that's approximately 4 months, which is a reasonable window for syncing vl results that have taken long to process in the lab and may not have been synced yet.
sixty_days_ago = Date.today - 120.days
start_date = [sixty_days_ago, minimum_date].max.to_s

Lab::Lims::Worker.start(start_date: start_date)
