class SolidQueue::ScheduledExecution < SolidQueue::Execution
  scope :due, -> { where("scheduled_at <= ?", Time.current) }
  scope :ordered, -> { order(scheduled_at: :asc, priority: :asc) }
  scope :next_batch, ->(batch_size) { due.ordered.limit(batch_size) }

  assume_attributes_from_job :scheduled_at

  class << self
    def prepare_batch(batch)
      prepared_at = Time.current

      rows = batch.map do |scheduled_execution|
        scheduled_execution.execution_ready_attributes.merge(created_at: prepared_at)
      end

      if rows.any?
        transaction do
          SolidQueue::ReadyExecution.insert_all(rows)
          where(id: batch.map(&:id)).delete_all
        end
      end

      SolidQueue.logger.info("[SolidQueue] Prepared scheduled batch with #{rows.size} jobs at #{prepared_at}")
    end
  end

  def execution_ready_attributes
    attributes.slice("job_id", "queue_name", "priority")
  end
end
