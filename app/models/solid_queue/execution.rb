class SolidQueue::Execution < ActiveRecord::Base
  self.abstract_class = true

  belongs_to :job

  private
    def assume_attributes_from_job
      self.queue_name ||= job&.queue_name
      self.priority ||= job&.priority
    end

end
