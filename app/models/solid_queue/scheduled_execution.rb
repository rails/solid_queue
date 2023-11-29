class SolidQueue::ScheduledExecution < SolidQueue::Execution
  scope :due, -> { where(scheduled_at: ..Time.current) }
  scope :ordered, -> { order(scheduled_at: :asc, priority: :asc) }
  scope :next_batch, ->(batch_size) { due.ordered.limit(batch_size) }

  assume_attributes_from_job :scheduled_at

  class << self
    def prepare_next_batch(batch_size)
      transaction do
        prepared_job_ids = prepare_batch next_batch(batch_size).lock("FOR UPDATE SKIP LOCKED").tap(&:load)
        prepared_job_ids.present?
      end
    end

    private
      def prepare_batch(batch)
        prepared_at = Time.current

        rows = batch.map do |scheduled_execution|
          scheduled_execution.ready_attributes.merge(created_at: prepared_at)
        end

        if rows.empty? then []
        else
          SolidQueue::ReadyExecution.insert_all(rows)
          SolidQueue::ReadyExecution.where(job_id: batch.map(&:job_id)).pluck(:job_id).tap do |enqueued_job_ids|
            where(job_id: enqueued_job_ids).delete_all
          end
        end
      end
  end
end
