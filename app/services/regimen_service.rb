# frozen_string_literal: true

class RegimenService
  ENGINES = {
    'HIV PROGRAM' => ArtService::RegimenEngine,
    'TB PROGRAM' => TbService::RegimenEngine
  }.freeze

  def initialize(program_id:)
    @engine = load_engine program_id
  end

  def method_missing(method, *args, **kwargs, &block)
    Rails.logger.debug "Executing missing method: #{method}. With these arguments: #{args} #{kwargs}"
    return @engine.send(method, *args, **kwargs, &block) if respond_to_missing?(method)

    super(method, *args, **kwargs, &block)
  end

  def respond_to_missing?(method, include_private = false)
    Rails.logger.debug "Engine responds to #{method}? #{@engine.respond_to?(method)}"
    @engine.respond_to?(method) || super
  end

  private

  def load_engine(program_id)
    program = Program.find program_id

    engine = ENGINES[program.name.upcase]
    engine.new program:
  end
end
