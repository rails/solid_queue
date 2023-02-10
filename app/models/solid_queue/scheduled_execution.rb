class SolidQueue::ScheduledExecution < SolidQueue::Execution
  scope :ordered, -> { order(scheduled_at: :asc, priority: :asc) }
  scope :due, -> { where("scheduled_at <= ?", Time.current) }

  before_create :assume_attributes_from_job

  def self.prepare_batch(batch)
    prepared_at = Time.current

    rows = batch.map do |scheduled_execution|
      scheduled_execution.execution_ready_attributes.merge(created_at: prepared_at)
    end

    SolidQueue::ReadyExecution.insert_all(rows) if rows.any?
  end

  def execution_ready_attributes
    attributes.slice("job_id", "queue_name", "priority")
  end

  private
    def assume_attributes_from_job
      super
      self.scheduled_at ||= job&.scheduled_at
    end
end
