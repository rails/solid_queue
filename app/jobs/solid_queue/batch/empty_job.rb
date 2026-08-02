# frozen_string_literal: true

module SolidQueue
  class Batch
    class EmptyJob < (defined?(ApplicationJob) ? ApplicationJob : ActiveJob::Base)
      # Always use Solid Queue, even when ApplicationJob uses another adapter.
      self.queue_adapter = :solid_queue

      def perform
        # This job does nothing - it just exists to trigger batch completion
        # The batch completion will be handled by the normal job_finished! flow
      end
    end
  end
end
