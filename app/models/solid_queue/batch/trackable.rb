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

      def progress_percentage
        return 0 if total_jobs == 0
        ((completed_jobs + failed_jobs) * 100.0 / total_jobs).round(2)
      end
    end
  end
end
