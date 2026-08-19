# frozen_string_literal: true

module SolidQueue
  class Batch
    # Repairs batches that the regular completion detection can't finish on
    # its own: jobs removed via bulk discards, processes that crashed after
    # enqueueing jobs but before starting their batch, or completions whose
    # callback enqueueing failed and rolled back.
    module Sweepable
      extend ActiveSupport::Concern

      class_methods do
        def sweep_stalled(stalled_for: 5.minutes, batch_size: 500)
          SolidQueue.instrument(:sweep_stalled_batches, stalled_for: stalled_for, stale_executions: 0, finished_batches: 0, started_batches: 0) do |payload|
            payload[:stale_executions] = sweep_stale_executions(batch_size:)
            payload[:finished_batches] = finish_stalled_batches(batch_size:)
            payload[:started_batches] = start_stalled_batches(stalled_for:, batch_size:)
          end
        end

        private
          # BatchExecution rows represent outstanding work. A row for a resolved
          # job violates that invariant, so remove it immediately; destroy's
          # after_commit callback retries the batch completion check.
          def sweep_stale_executions(batch_size:)
            swept = 0

            [ BatchExecution.with_finished_jobs, BatchExecution.with_failed_jobs ].each do |stale|
              stale.find_each(batch_size: batch_size) do |batch_execution|
                swept += 1
                batch_execution.destroy
              end
            end

            swept
          end

          # A started batch with no tracking rows left can finish
          def finish_stalled_batches(batch_size:)
            finished = 0

            unfinished.enqueued.without_executions.find_each(batch_size: batch_size) do |batch|
              finished += 1
              batch.finish
            end

            finished
          end

          # A batch that crashed between creation and start never got enqueued
          def start_stalled_batches(stalled_for:, batch_size:)
            started = 0

            unfinished.where(enqueued_at: nil).where(created_at: ...stalled_for.ago).find_each(batch_size: batch_size) do |batch|
              started += 1
              batch.start
            end

            started
          end
      end
    end
  end
end
