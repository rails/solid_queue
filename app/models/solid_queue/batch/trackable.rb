# frozen_string_literal: true

module SolidQueue
  class Batch
    module Trackable
      extend ActiveSupport::Concern

      included do
        scope :pending, -> { where(status: "pending") }
        scope :processing, -> { where(status: "processing") }
        scope :completed, -> { where(status: "completed") }
        scope :failed, -> { where(status: "failed") }
        scope :finished, -> { where(status: %w[completed failed]) }
        scope :unfinished, -> { where(status: %w[pending processing]) }
      end

      def finished?
        status.in?(%w[completed failed])
      end

      def processing?
        status == "processing"
      end

      def pending?
        status == "pending"
      end

      def progress_percentage
        return 0 if total_jobs == 0
        ((completed_jobs + failed_jobs) * 100.0 / total_jobs).round(2)
      end
    end
  end
end
