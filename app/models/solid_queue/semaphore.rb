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
      def self.signal_all(jobs)
        Semaphore.where(key: jobs.map(&:concurrency_key)).update_all("value = value + 1")
      end

      def initialize(job)
        @job = job
      end

      def wait
        if semaphore = Semaphore.lock.find_by(key: key)
          @generation = semaphore.generation.to_i
          current = limit
          if current <= 0
            persist_closed!(semaphore)
            false
          else
            sync_limit!(semaphore, current)
            semaphore.value > 0 && attempt_decrement
          end
        else
          @generation = 0
          current = limit
          if current <= 0
            Semaphore.create_unique_by(key: key, value: 0, limit: 0, generation: 0, expires_at: expires_at)
            false
          else
            attempt_creation(current)
          end
        end
      end

      def signal
        attempt_increment
      end

      private
        attr_accessor :job

        def attempt_creation(current_limit)
          if Semaphore.create_unique_by(key: key, value: current_limit - 1, limit: current_limit, generation: 0, expires_at: expires_at)
            true
          else
            current_limit == 1 ? false : attempt_decrement
          end
        end

        def attempt_decrement
          Semaphore.available.where(key: key).update_all([ "value = value - 1, expires_at = ?", expires_at ]) > 0
        end

        def attempt_increment
          Semaphore.where(key: key, value: ...limit).update_all([ "value = value + 1, expires_at = ?", expires_at ]) > 0
        end

        def sync_limit!(semaphore, current)
          stored = semaphore.limit
          return if stored == current

          old = stored.nil? ? current : stored
          new_value = [ semaphore.value + (current - old), 0 ].max
          attrs = { limit: current, value: new_value, expires_at: expires_at, updated_at: Time.current }
          attrs[:generation] = semaphore.generation.to_i + 1 unless stored.nil?
          semaphore.update_columns(attrs)
          semaphore.value = new_value
          semaphore.limit = current
          semaphore.generation = attrs[:generation] if attrs[:generation]
        end

        def persist_closed!(semaphore)
          generation = semaphore.generation.to_i + 1
          semaphore.update_columns(
            limit: 0,
            value: 0,
            generation: generation,
            expires_at: expires_at,
            updated_at: Time.current
          )
          semaphore.value = 0
          semaphore.limit = 0
          semaphore.generation = generation
          Concurrency::LimitCache.delete(key)
        end

        def key
          job.concurrency_key
        end

        def expires_at
          job.concurrency_duration.from_now
        end

        def limit
          @limit ||= resolve_limit
        end

        def resolve_limit
          if job.is_a?(SolidQueue::Job)
            job.concurrency_limit(generation: @generation.to_i)
          else
            raw = job.concurrency_limit
            return 1 if raw.nil?
            return raw.to_i unless raw.respond_to?(:call)

            Concurrency::LimitCache.fetch(job.concurrency_key, generation: @generation.to_i) do
              job.instance_exec(*Array(job.arguments), &raw).to_i
            end
          end
        end
    end
  end
end
