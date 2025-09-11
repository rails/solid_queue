# frozen_string_literal: true

module SolidQueue
  class BatchMonitorJob < (defined?(ApplicationJob) ? ApplicationJob : ActiveJob::Base)
    POLLING_INTERVAL = 1.seconds

    def perform(batch_id:)
      batch = Batch.find_by(batch_id: batch_id)
      return unless batch

      return if batch.finished?

      loop do
        batch.reload

        break if batch.finished?

        if check_completion?(batch)
          batch.check_completion!
          break if batch.reload.finished?
        end

        sleep(POLLING_INTERVAL)
      end
    rescue => e
      Rails.logger.error "[SolidQueue] BatchMonitorJob error for batch #{batch_id}: #{e.message}"
      # Only re-enqueue on error, with a delay
      self.class.set(wait: 30.seconds).perform_later(batch_id: batch_id)
    end

    private

      def check_completion?(batch)
        has_incomplete_children = batch.child_batches.where(finished_at: nil).exists?
        !has_incomplete_children && batch.pending_jobs <= 0 && batch.total_jobs > 0
      end
  end
end
