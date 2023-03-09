class ErrorBuffer
  attr_reader :errors

  def initialize
    @errors = Concurrent::Array.new
  end

  def report(error, handled:, severity:, context:, source: nil)
    errors << [ error, { context: context, handled: handled, level: severity, source: source } ]
  end

  def messages
    errors.map { |error| error.first.message }
  end
end
