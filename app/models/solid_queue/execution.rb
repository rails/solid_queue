module SolidQueue
  class Execution < SolidQueue::Record
    include JobAttributes

    self.abstract_class = true

    belongs_to :job

    alias_method :discard, :destroy

    class << self
      def queued_as(queues)
        QueueParser.new(queues, self).scoped_relation
      end
    end
  end
end
