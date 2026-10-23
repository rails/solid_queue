class LargeErrorMessageJob < ApplicationJob
  queue_as :background

  def perform(message_size)
    raise ExpectedTestError, "x" * message_size
  end
end
