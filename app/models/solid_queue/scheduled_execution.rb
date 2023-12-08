class SolidQueue::ScheduledExecution < SolidQueue::Execution
  scope :due, -> { where(scheduled_at: ..Time.current) }
  scope :ordered, -> { order(scheduled_at: :asc, priority: :asc) }
  scope :next_batch, ->(batch_size) { due.ordered.limit(batch_size) }

  assume_attributes_from_job :scheduled_at

  class << self
    def dispatch_next_batch(batch_size)
      transaction do
        dispatch_batch next_batch(batch_size).lock("FOR UPDATE SKIP LOCKED").tap(&:load)
      end
    end

    private
      def dispatch_batch(batch)
        if batch.empty? then []
        else
          promote_batch_to_ready(batch)
        end
      end

      def promote_batch_to_ready(batch)
        rows = ready_rows_from_batch(batch)

        SolidQueue::ReadyExecution.insert_all(rows)
        SolidQueue::ReadyExecution.where(job_id: batch.map(&:job_id)).pluck(:job_id).tap do |enqueued_job_ids|
          where(job_id: enqueued_job_ids).delete_all

          SolidQueue.logger.info("[SolidQueue] Dispatched scheduled batch with #{enqueued_job_ids.size} jobs")
        end
      end

      def ready_rows_from_batch(batch)
        prepared_at = Time.current

        batch.map do |scheduled_execution|
          scheduled_execution.ready_attributes.merge(created_at: prepared_at)
        end
      end
  end
end
