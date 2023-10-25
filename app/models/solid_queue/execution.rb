class SolidQueue::Execution < SolidQueue::Record
  self.abstract_class = true

  belongs_to :job

  alias_method :discard, :destroy

  private
    def assume_attributes_from_job
      self.queue_name ||= job&.queue_name
      self.priority = job&.priority if job&.priority.to_i > priority
    end
end
