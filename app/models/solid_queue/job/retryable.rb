# frozen_string_literal: true

module SolidQueue
  class Job
    module Retryable
      extend ActiveSupport::Concern

      included do
        has_one :failed_execution

        scope :failed, -> { includes(:failed_execution).where.not(failed_execution: { id: nil }) }
      end

      def retry
        failed_execution&.retry
      end

      def failed_with(exception)
        FailedExecution.create_or_find_by!(job_id: id, exception: exception)
      end

      def reset_execution_counters
        arguments["executions"] = 0
        arguments["exception_executions"] = {}
        save!
      end
    end
  end
end
