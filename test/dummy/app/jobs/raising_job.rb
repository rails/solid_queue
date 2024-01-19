class RaisingJob < ApplicationJob
  class DefaultError < StandardError; end
  class DiscardableError < StandardError; end

  queue_as :background

  retry_on DefaultError, attempts: 3, wait: 0.1.seconds
  discard_on DiscardableError

  def perform(raising, identifier, attempts = 1)
    raising = raising.shift if raising.is_a?(Array)

    if raising && executions <= attempts
      JobBuffer.add("#{identifier}: raised #{raising} for the #{executions.ordinalize} time")
      raise raising, "This is a #{raising} exception"
    else
      JobBuffer.add("Successfully completed job")
    end
  end
end
