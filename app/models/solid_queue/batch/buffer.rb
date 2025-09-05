# frozen_string_literal: true

module SolidQueue
  class Batch
    class Buffer
      attr_reader :jobs, :child_batches

      def initialize
        @jobs = {}
        @child_batches = []
      end

      def add(job)
        @jobs[job.job_id] = job
        job
      end

      def add_child_batch(batch)
        @child_batches << batch
        batch
      end

      def capture
        previous_buffer = ActiveSupport::IsolatedExecutionState[:solid_queue_batch_buffer]
        ActiveSupport::IsolatedExecutionState[:solid_queue_batch_buffer] = self

        yield

        @jobs
      ensure
        ActiveSupport::IsolatedExecutionState[:solid_queue_batch_buffer] = previous_buffer
      end

      def self.current
        ActiveSupport::IsolatedExecutionState[:solid_queue_batch_buffer]
      end

      def self.capture_job(job)
        current&.add(job)
      end

      def self.capture_child_batch(batch)
        current&.add_child_batch(batch)
      end
    end
  end
end
