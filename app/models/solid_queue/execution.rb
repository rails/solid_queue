class SolidQueue::Execution < ActiveRecord::Base
  self.abstract_class = true

  belongs_to :job
end
