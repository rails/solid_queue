class ShardTwoJob < ApplicationJob
  self.queue_adapter = ActiveJob::QueueAdapters::SolidQueueAdapter.new(db_shard: :queue_shard_two)
  queue_as :background

  def perform(arg)
    JobBuffer.add(arg)
  end
end
