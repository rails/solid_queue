# frozen_string_literal: true

module SolidQueue
  class Record < ActiveRecord::Base
    self.abstract_class = true

    connects_to(**SolidQueue.connects_to) if SolidQueue.connects_to

    def self.clear_all_connections!
      self.connection_handler.clear_all_connections!(:writing)
      self.connection_handler.clear_all_connections!(:reading)
    end

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
