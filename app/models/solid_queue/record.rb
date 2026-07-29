# frozen_string_literal: true

module SolidQueue
  class Record < ActiveRecord::Base
    self.abstract_class = true
    self.strict_loading_by_default = false

    include DistinctValues

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

      def warn_about_pending_migrations
        SolidQueue.deprecator.warn(<<~DEPRECATION)
          Solid Queue has pending database migrations. To get the new migration files, run:
            rails solid_queue:update
          And then:
            rails db:migrate
          These migrations will be required after version #{SolidQueue.next_major_version}.0
        DEPRECATION
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
