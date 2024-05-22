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

      def signal_all(jobs)
        Proxy.signal_all(jobs)
      end
    end

    class Proxy
      def self.signal_all(jobs)
        Semaphore.where(key: jobs.map(&:concurrency_key)).update_all("value = value + 1")
      end

      def initialize(job)
        @job = job
      end

      def wait
        if semaphore = Semaphore.find_by(key: key)
          semaphore.value > 0 && attempt_decrement
        else
          attempt_creation
        end
      end

      def signal
        attempt_increment
      end

      private

        attr_accessor :job

        def attempt_creation_with_insert_on_conflict
          results = Semaphore.insert({ key: key, value: limit - 1, expires_at: expires_at }, unique_by: :key)

          if results.length.zero?
            limit == 1 ? false : attempt_decrement
          else
            true
          end
        end

        def attempt_creation_with_create_and_exception_handling
          Semaphore.create!(key: key, value: limit - 1, expires_at: expires_at)
          true
        rescue ActiveRecord::RecordNotUnique
          limit == 1 ? false : attempt_decrement
        end

        if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
          alias attempt_creation attempt_creation_with_insert_on_conflict
        else
          alias attempt_creation attempt_creation_with_create_and_exception_handling
        end

        def attempt_decrement
          Semaphore.available.where(key: key).update_all([ "value = value - 1, expires_at = ?", expires_at ]) > 0
        end

        def attempt_increment
          Semaphore.where(key: key, value: ...limit).update_all([ "value = value + 1, expires_at = ?", expires_at ]) > 0
        end

        def key
          job.concurrency_key
        end

        def expires_at
          job.concurrency_duration.from_now
        end

        def limit
          job.concurrency_limit || 1
        end
    end
  end
end
