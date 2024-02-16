# frozen_string_literal: true

module SolidQueue
  class Job
    module Executable
      extend ActiveSupport::Concern

      included do
        include Clearable, ConcurrencyControls, Schedulable

        has_one :ready_execution
        has_one :claimed_execution
        has_one :failed_execution

        after_create :prepare_for_execution

        scope :finished, -> { where.not(finished_at: nil) }
        scope :failed, -> { includes(:failed_execution).where.not(failed_execution: { id: nil }) }
      end

      class_methods do
        def prepare_all_for_execution(jobs)
          due, not_yet_due = jobs.partition(&:due?)
          dispatch_all(due) + schedule_all(not_yet_due)
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

          def dispatch_all_one_by_one(jobs)
            jobs.each(&:dispatch)
          end

          def successfully_dispatched(jobs)
            dispatched_and_ready(jobs) + dispatched_and_blocked(jobs)
          end

          def dispatched_and_ready(jobs)
            where(id: ReadyExecution.where(job_id: jobs.map(&:id)).pluck(:job_id))
          end

          def dispatched_and_blocked(jobs)
            where(id: BlockedExecution.where(job_id: jobs.map(&:id)).pluck(:job_id))
          end
      end

      %w[ ready claimed failed ].each do |status|
        define_method("#{status}?") { public_send("#{status}_execution").present? }
      end

      def prepare_for_execution
        if due? then dispatch
        else
          schedule
        end
      end

      def dispatch
        if acquire_concurrency_lock then ready
        else
          block
        end
      end

      def dispatch_bypassing_concurrency_limits
        ready
      end

      def finished!
        if SolidQueue.preserve_finished_jobs?
          touch(:finished_at)
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
          execution.model_name.element.sub("_execution", "").to_sym
        end
      end

      def retry
        failed_execution&.retry
      end

      def discard
        execution&.discard
      end

      def failed_with(exception)
        FailedExecution.create_or_find_by!(job_id: id, exception: exception)
      end

      private
        def ready
          ReadyExecution.create_or_find_by!(job_id: id)
        end

        def execution
          %w[ ready claimed failed ].reduce(nil) { |acc, status| acc || public_send("#{status}_execution") }
        end
    end
  end
end
