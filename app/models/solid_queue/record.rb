# frozen_string_literal: true

module SolidQueue
  class Record < ActiveRecord::Base
    self.abstract_class = true

    def self.connects_to_and_set_active_shard
      connects_to(**SolidQueue.connects_to)

      if SolidQueue.connects_to.key?(:shards) &&
           SolidQueue.connects_to[:shards].key?(SolidQueue.active_shard)
        self.default_shard = SolidQueue.active_shard
      end
    end

    connects_to_and_set_active_shard if SolidQueue.connects_to

    def self.non_blocking_lock
      if SolidQueue.use_skip_locked
        lock(Arel.sql("FOR UPDATE SKIP LOCKED"))
      else
        lock
      end
    end
  end
end

ActiveSupport.run_load_hooks :solid_queue_record, SolidQueue::Record
