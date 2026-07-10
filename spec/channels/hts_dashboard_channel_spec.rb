# frozen_string_literal: true

require 'rails_helper'

RSpec.describe HtsDashboardChannel, type: :channel do
  it 'subscribes and streams from the shared HTS dashboard stream' do
    subscribe

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(HtsDashboardChannel::STREAM)
  end
end
