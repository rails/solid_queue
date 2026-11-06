# frozen_string_literal: true

module SolidQueue
  class Job
    module Executable
      extend ActiveSupport::Concern

      included do
        include ConcurrencyControls, Schedulable, Retryable

        has_one :ready_execution
        has_one :claimed_execution

        after_create :prepare_for_execution

        # Set when enqueueing, for a job that acquires its concurrency lock when
        # it's dispatched instead of right away. See SolidQueue.concurrency_lock_acquisition.
        attr_writer :defer_concurrency_lock

        scope :finished, -> { where.not(finished_at: nil) }
      end

      class_methods do
        def prepare_all_for_execution(jobs)
          # Track before dispatch so conflict-discarded jobs count like single enqueues.
          batch_all(jobs)

          dispatchable, schedulable = jobs.partition(&:dispatchable_on_enqueue?)
          dispatch_all(dispatchable) + schedule_all(schedulable)
        end

        def dispatch_all(jobs)
          with_concurrency_limits, without_concurrency_limits = jobs.partition(&:concurrency_limited?)

          dispatch_all_at_once(without_concurrency_limits)
          dispatch_all_one_by_one(with_concurrency_limits)

          successfully_dispatched(jobs)
        end

        private
          def dispatch_all_at_once(jobs)
            ReadyExecution.create_all_from_jobs jobs
          end

          # Each job acquires its concurrency lock here, and holds it until the
          # transaction dispatching the whole set ends. Going through them by
          # concurrency key makes everyone dispatching at the same time acquire
          # the locks they share in the same order, so they can't deadlock.
          def dispatch_all_one_by_one(jobs)
            jobs.sort_by { |job| [ job.concurrency_key, job.id ] }.each(&:dispatch)
          end

          def successfully_dispatched(jobs)
            jobs_by_id = jobs.index_by(&:id)
            dispatched_and_ready(jobs_by_id) + dispatched_and_blocked(jobs_by_id)
          end

          def dispatched_and_ready(jobs_by_id)
            ReadyExecution.where(job_id: jobs_by_id.keys).pluck(:job_id).map { |id| jobs_by_id[id] }
          end

          def dispatched_and_blocked(jobs_by_id)
            BlockedExecution.where(job_id: jobs_by_id.keys).pluck(:job_id).map { |id| jobs_by_id[id] }
          end
      end

      %w[ ready claimed failed ].each do |status|
        define_method("#{status}?") { public_send("#{status}_execution").present? }
      end

      def prepare_for_execution
        if dispatchable_on_enqueue? then dispatch
        else
          schedule
        end
      end

      # A job that defers its concurrency lock is scheduled even when it's due:
      # the dispatcher acquires the lock once the job is committed, outside the
      # transaction that enqueued it.
      def dispatchable_on_enqueue?
        due? && !defer_concurrency_lock?
      end

      def defer_concurrency_lock?
        @defer_concurrency_lock.present? && concurrency_limited?
      end

      def dispatch
        if acquire_concurrency_lock then ready
        else
          handle_concurrency_conflict
        end
      end

      def dispatch_bypassing_concurrency_limits
        ready
      end

      def finished!
        if SolidQueue.preserve_finished_jobs?
          # update! rather than touch so the batch tracking callbacks run
          update!(finished_at: Time.current)
        else
          destroy!
        end
      end

      def finished?
        finished_at.present?
      end

      def status
        if finished?
          :finished
        elsif execution.present?
          execution.type
        end
      end

      def discard
        execution&.discard
      end

      private
        def ready
          ReadyExecution.create_or_find_by!(job: self)
        end

        def execution
          %w[ ready claimed failed ].reduce(nil) { |acc, status| acc || public_send("#{status}_execution") }
        end
    end
  end
end
