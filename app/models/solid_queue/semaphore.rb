# frozen_string_literal: true

module SolidQueue
  class Semaphore < Record
    scope :available, -> { where("value > 0") }
    scope :expired, -> { where(expires_at: ...Time.current) }

    class << self
      def wait(job)
        Proxy.new(job).wait
      end

      def signal(job)
        Proxy.new(job).signal
      end

      # Requires a unique index on key
      def create_unique_by(attributes)
        if supports_insert_conflict_target?
          insert({ **attributes }, unique_by: :key).any?
        else
          create!(**attributes)
        end
      rescue ActiveRecord::RecordNotUnique
        false
      end
    end

    class Proxy
      def initialize(job)
        @job = job
      end

      # Returns the id of the semaphore the job got a slot on, or nil if there was none free
      def wait
        if semaphore = Semaphore.lock.find_by(key: key)
          semaphore.id if semaphore.value > 0 && attempt_decrement
        else
          attempt_creation
        end
      end

      def signal
        attempt_increment
      end

      private
        attr_accessor :job

        def attempt_decrement
          Semaphore.available.where(key: key).update_all([ "value = value - 1, expires_at = ?", expires_at ]) > 0
        end

        def attempt_creation
          if Semaphore.create_unique_by(key: key, value: limit - 1, expires_at: expires_at)
            acquired_semaphore_id
          else
            check_limit_or_decrement
          end
        end

        # A locking read, so it sees the latest committed rows rather than the transaction's
        # snapshot, which on MySQL can still include a semaphore that expired and was deleted
        def acquired_semaphore_id
          Semaphore.lock.where(key: key).pick(:id)
        end

        def check_limit_or_decrement
          acquired_semaphore_id if limit > 1 && attempt_decrement
        end

        def attempt_increment
          semaphore_to_release.where(value: ...limit_to_release).update_all([ "value = value + 1, expires_at = ?", expires_at ]) > 0
        end

        # A job only gives its slot back to the semaphore it got it from. If that one expired
        # and was deleted, a semaphore for the same key now belongs to other jobs.
        # Jobs dispatched before Solid Queue recorded their semaphore give it back by key.
        def semaphore_to_release
          if job.acquired_semaphore_id
            Semaphore.where(id: job.acquired_semaphore_id)
          else
            Semaphore.where(key: key)
          end
        end

        # Recorded when the job got its slot, so it's known even if the job's class no longer loads
        def limit_to_release
          job.acquired_concurrency_limit || limit
        end

        def key
          job.concurrency_key
        end

        def expires_at
          job.concurrency_duration.from_now
        end

        def limit
          job.concurrency_limit
        end
    end
  end
end
