# frozen_string_literal: true

module SolidQueue
  module Concurrency
    class << self
      # Re-evaluate a key's cap and move blocked/ready jobs to match.
      # Pass +to:+ when the new limit is already known (avoids a job/proc).
      def refresh(key, to: nil)
        LimitCache.delete(key)

        semaphore = Semaphore.lock.find_by(key: key)
        return 0 unless semaphore

        new_limit = to.nil? ? semaphore.limit : to.to_i
        return 0 if new_limit.nil?

        old_limit = semaphore.limit || new_limit
        delta = new_limit - old_limit
        new_value = [ semaphore.value + delta, 0 ].max

        semaphore.update!(
          limit: new_limit,
          value: new_value,
          generation: semaphore.generation.to_i + 1
        )

        if new_limit <= 0
          reblock_ready(key, ready_count(key))
        elsif delta.positive?
          BlockedExecution.release_many(Array.new(new_value, key))
        elsif delta.negative?
          reblock_ready(key, excess_ready(key, new_limit))
        else
          0
        end
      end

      private
        def ready_count(key)
          ReadyExecution.joins(:job).where(solid_queue_jobs: { concurrency_key: key }).count
        end

        def claimed_count(key)
          ClaimedExecution.joins(:job).where(solid_queue_jobs: { concurrency_key: key }).count
        end

        def excess_ready(key, limit)
          allowed_ready = [ limit - claimed_count(key), 0 ].max
          [ ready_count(key) - allowed_ready, 0 ].max
        end

        def reblock_ready(key, count)
          return 0 if count < 1

          executions = ReadyExecution.joins(:job)
            .where(solid_queue_jobs: { concurrency_key: key })
            .order("solid_queue_ready_executions.id")
            .limit(count)
            .to_a

          executions.each do |ready|
            job = ready.job
            BlockedExecution.create!(
              job_id: job.id,
              queue_name: ready.queue_name,
              priority: ready.priority,
              concurrency_key: key,
              expires_at: job.concurrency_duration.from_now
            )
            ready.destroy!
          end

          executions.size
        end
    end
  end
end
