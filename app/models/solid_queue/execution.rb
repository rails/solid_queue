module SolidQueue
  class Execution < SolidQueue::Record
    include JobAttributes

    self.abstract_class = true

    scope :ordered, -> { order(priority: :asc, job_id: :asc) }

    belongs_to :job

    alias_method :discard, :destroy
  end
end
