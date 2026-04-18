# frozen_string_literal: true

module SolidQueue
  class Record < ActiveRecord::Base
    self.abstract_class = true

    connects_to(**SolidQueue.connects_to) if SolidQueue.connects_to

    class << self
      def non_blocking_lock
        if SolidQueue.use_skip_locked
          lock(Arel.sql("FOR UPDATE SKIP LOCKED"))
        else
          lock
        end
      end

      def supports_insert_conflict_target?
        connection_pool.with_connection do |connection|
          connection.supports_insert_conflict_target?
        end
      end

      # Pass index hints to the query optimizer using SQL comment hints.
      # Uses MySQL 8 optimizer hint query comments, which SQLite and
      # PostgreSQL ignore.
      def use_index(*indexes)
        optimizer_hints "INDEX(#{quoted_table_name} #{indexes.join(', ')})"
      end
    end
  end
end

ActiveSupport.run_load_hooks :solid_queue_record, SolidQueue::Record
