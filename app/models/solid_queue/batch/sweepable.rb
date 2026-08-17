# frozen_string_literal: true

module SolidQueue
  class Batch
    # Repairs batches that the regular completion detection can't finish on
    # its own: jobs removed via bulk discards, processes that crashed after
    # enqueueing jobs but before starting their batch, or completions whose
    # callback enqueueing failed and rolled back.
    module Sweepable
      extend ActiveSupport::Concern

      COMPLETION_GRACE = 3.seconds

      class_methods do
        def sweep_stalled(stalled_for: 5.minutes, batch_size: 500)
          SolidQueue.instrument(:sweep_stalled_batches, stalled_for: stalled_for, size: 0, started: 0, repaired: 0) do |payload|
            # BatchExecution rows represent outstanding work. A row for a resolved
            # job violates that invariant, so remove it immediately; destroy's
            # after_commit callback retries the batch completion check.
            [ BatchExecution.for_finished_jobs, BatchExecution.for_failed_jobs ].each do |leaked|
              leaked.find_each(batch_size: batch_size) do |batch_execution|
                payload[:repaired] += 1
                batch_execution.destroy
              end
            end

            # A started batch with no tracking rows can finish, but allow time for a
            # transaction-deferred EmptyJob enqueue to become visible.
            unfinished.empty_executions.where(enqueued_at: ...COMPLETION_GRACE.ago).find_each(batch_size: batch_size) do |batch|
              payload[:size] += 1
              batch.check_completion
            end

            unfinished.where(enqueued_at: nil).where(created_at: ...stalled_for.ago).find_each(batch_size: batch_size) do |batch|
              payload[:started] += 1
              batch.start_batch
            end
          end
        end
      end
    end
  end
end
