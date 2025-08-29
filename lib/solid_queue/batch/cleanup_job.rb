# frozen_string_literal: true

module SolidQueue
  class Batch
    class CleanupJob < ApplicationJob
      queue_as :background

      discard_on ActiveRecord::RecordNotFound

      def perform(job_batch)
        return if SolidQueue.preserve_finished_jobs?

        job_batch.jobs.finished.destroy_all
      end
    end
  end
end
