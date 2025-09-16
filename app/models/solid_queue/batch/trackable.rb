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
        scope :by_batch_id, ->(batch_id) { where(batch_id:) }
        scope :empty_executions, -> {
          where(<<~SQL)
            NOT EXISTS (
              SELECT 1 FROM solid_queue_batch_executions
              WHERE solid_queue_batch_executions.batch_id = solid_queue_batches.batch_id
              LIMIT 1
            )
          SQL
        }
      end

      def status
        if finished?
          failed? ? "failed" : "completed"
        elsif enqueued_at.present?
          "processing"
        else
          "pending"
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

      def ready?
        enqueued_at.present?
      end

      def completed_jobs
        finished? ? self[:completed_jobs] : total_jobs - batch_executions.count
      end

      def failed_jobs
        finished? ? self[:failed_jobs] : jobs.joins(:failed_execution).count
      end

      def pending_jobs
        finished? ? self[:pending_jobs] : batch_executions.count
      end

      def progress_percentage
        return 0 if total_jobs == 0
        ((completed_jobs + failed_jobs) * 100.0 / total_jobs).round(2)
      end
    end
  end
end
