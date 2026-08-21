# frozen_string_literal: true

module SolidQueue
  class Batch
    module Trackable
      extend ActiveSupport::Concern

      included do
        scope :finished, -> { where.not(finished_at: nil) }
        scope :succeeded, -> { finished.where(failed_at: nil) }
        scope :unfinished, -> { where(finished_at: nil) }
        scope :failed, -> { where.not(failed_at: nil) }
        scope :enqueued, -> { where.not(enqueued_at: nil) }
        # Join-free so update_all keeps this condition in the completion update's own WHERE
        scope :empty_executions, -> { where.not(id: BatchExecution.select(:batch_id)) }
      end

      def status
        if finished?
          failed? ? :failed : :completed
        elsif enqueued?
          :enqueued
        else
          :pending
        end
      end

      def failed?
        failed_at.present?
      end

      def succeeded?
        finished? && !failed?
      end

      def finished?
        finished_at.present?
      end

      def enqueued?
        enqueued_at.present?
      end

      # Failed jobs no longer have tracking rows, so exclude them from the completed count.
      def completed_jobs
        finished? ? self[:completed_jobs] : total_jobs - pending_jobs - failed_jobs
      end

      def failed_jobs
        finished? ? self[:failed_jobs] : jobs.failed.count
      end

      def pending_jobs
        finished? ? 0 : batch_executions.count
      end

      def progress_percentage
        return 0 if total_jobs == 0
        ((total_jobs - pending_jobs) * 100.0 / total_jobs).round(2)
      end
    end
  end
end
