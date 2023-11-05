class SolidQueue::Execution < SolidQueue::Record
  include JobAttributes

  self.abstract_class = true

  belongs_to :job

  alias_method :discard, :destroy
end
