# frozen_string_literal: true

module SolidQueue
  class CoalesceKey < Record
    class PendingMigrations < StandardError
      def initialize(message = "The coalescing schema hasn't been installed yet. Run `bin/rails solid_queue:update` to copy the pending migrations to your application, and then `bin/rails db:migrate` to run them")
        super
      end
    end

    belongs_to :job, optional: true

    class << self
      def migrated?
        @migrated ||= table_exists?
      end

      # Locked until the transaction commits, so the key's job can't be claimed in the meantime
      def admit(key)
        insert_unless_held(key)

        # Retry if the key's job was claimed between the insert and the lock
        lock.find_by(key: key) || admit(key)
      end

      # Locks the keys in order, like bulk admission, so the two can't deadlock
      def release_all(job_ids)
        if migrated? && (ids = where(job_id: job_ids).order(:key).lock.ids).any?
          where(id: ids).delete_all
        end
      end

      private
        # PostgreSQL aborts the current transaction on a duplicate key, so skip
        # duplicates instead of raising
        def insert_unless_held(key)
          if supports_insert_conflict_target?
            insert({ key: key }, unique_by: :key)
          else
            insert({ key: key })
          end
        end
    end
  end
end
