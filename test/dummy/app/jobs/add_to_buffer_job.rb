class AddToBufferJob < ApplicationJob
  queue_as :background

  def perform(arg)
    JobBuffer.add(arg)
  end
end
