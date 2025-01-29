module MultishardingTestHelper
  private

  def connected_to_shard_two(&block)
    ActiveRecord::Base.connected_to(shard: :queue_shard_two) { block.call }
  end

  def change_active_shard_to(new_shard_name, &block)
    old_shard_name = SolidQueue.active_shard
    SolidQueue.active_shard = new_shard_name
    SolidQueue::Record.connects_to_and_set_active_shard
    block.call
  ensure
    SolidQueue.active_shard = old_shard_name
    SolidQueue::Record.connects_to_and_set_active_shard
  end
end
