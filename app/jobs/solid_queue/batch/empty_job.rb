# frozen_string_literal: true

module SolidQueue
  class Batch
    class EmptyJob < (defined?(ApplicationJob) ? ApplicationJob : ActiveJob::Base)
      # Pinned so it can't leak to another backend in mixed-adapter apps
      self.queue_adapter = :solid_queue

      def perform
        # This job does nothing - it just exists to trigger batch completion
        # The batch completion will be handled by the normal job_finished! flow
      end
    end
  end
end
