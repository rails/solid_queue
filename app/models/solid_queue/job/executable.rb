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

        scope :finished, -> { where.not(finished_at: nil) }
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
            job_ids = jobs.map(&:id)
            dispatched_ids = ReadyExecution.where(job_id: job_ids).pluck(:job_id) +
                             BlockedExecution.where(job_id: job_ids).pluck(:job_id)
            dispatched_ids = dispatched_ids.to_set
            jobs.select { |job| dispatched_ids.include?(job.id) }
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
          handle_concurrency_conflict
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
          execution.type
        end
      end

      def discard
        execution&.discard
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
