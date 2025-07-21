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

      def warn_about_pending_migrations
        SolidQueue.deprecator.warn(<<~DEPRECATION)
          Solid Queue has pending database migrations. To get the new migration files, run:
            rails solid_queue:update
          And then:
            rails db:migrate
          These migrations will be required after version 2.0
        DEPRECATION
      end
    end
  end
end

ActiveSupport.run_load_hooks :solid_queue_record, SolidQueue::Record
