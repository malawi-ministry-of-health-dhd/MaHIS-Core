# frozen_string_literal: true

require 'rails_helper'

# Browser dictation posts a recording here and gets text back. The audio is
# patient data, so this covers the guards as much as the happy path: nothing
# oversized gets forwarded, and a failure in the separate speech engine must not
# read as a MaHIS fault.
RSpec.describe TranscriptionService do
  let(:audio) do
    Rack::Test::UploadedFile.new(
      StringIO.new('fake-opus-bytes'),
      'audio/webm',
      original_filename: 'dictation.webm'
    )
  end

  def stub_engine(status:, body:)
    response = instance_double(Net::HTTPResponse, body:)
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(status == 200)
    allow(Net::HTTP).to receive(:new).and_return(instance_double(Net::HTTP).tap do |http|
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(response)
    end)
  end

  it 'returns the transcript from the speech engine' do
    stub_engine(status: 200, body: { text: '  patient reports chest pain  ' }.to_json)

    expect(described_class.transcribe(audio)).to eq('patient reports chest pain')
  end

  it 'tolerates an engine that returns a bare string' do
    stub_engine(status: 200, body: 'patient is stable')

    expect(described_class.transcribe(audio)).to eq('patient is stable')
  end

  it 'rejects a missing recording' do
    expect { described_class.transcribe(nil) }
      .to raise_error(described_class::TranscriptionError, /No audio/)
  end

  it 'rejects a recording that is too large to be a clinical note' do
    oversized = Rack::Test::UploadedFile.new(StringIO.new('x'), 'audio/webm', original_filename: 'big.webm')
    allow(oversized).to receive(:size).and_return(described_class::MAX_AUDIO_BYTES + 1)

    expect { described_class.transcribe(oversized) }
      .to raise_error(described_class::TranscriptionError, /too long/)
  end

  it 'reports a stopped engine as unavailable rather than a MaHIS failure' do
    allow(Net::HTTP).to receive(:new).and_raise(Errno::ECONNREFUSED)

    expect { described_class.transcribe(audio) }
      .to raise_error(described_class::TranscriptionError, /not running/)
  end

  it 'reports an engine error without leaking its response' do
    stub_engine(status: 500, body: 'internal engine stacktrace')

    expect { described_class.transcribe(audio) }
      .to raise_error(described_class::TranscriptionError, 'Transcription failed')
  end

  it 'talks to loopback by default so the engine is never network-exposed' do
    expect(described_class.endpoint).to start_with('http://127.0.0.1')
  end
end
