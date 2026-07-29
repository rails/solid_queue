# frozen_string_literal: true

module ShardingTestHelper
  private
    # Bypass the query cache like skip_active_record_query_cache does: it
    # disables it for the default shard's pool only, and processes running
    # in other threads write to the shards behind this thread's cache
    def on_shard(shard, &block)
      SolidQueue::Record.connected_to(shard: shard) do
        SolidQueue::Record.uncached(&block)
      end
    end

    def on_each_shard(&block)
      SolidQueue.shards.each { |shard| on_shard(shard) { block.call(shard) } }
    end

    def jobs_count_per_shard
      SolidQueue.shards.index_with { |shard| on_shard(shard) { SolidQueue::Job.count } }
    end
end
