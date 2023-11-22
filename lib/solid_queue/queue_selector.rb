# frozen_string_literal: true

module SolidQueue
  class QueueSelector
    attr_reader :raw_queues, :relation

    def initialize(queue_list, relation)
      @raw_queues = Array(queue_list).map { |queue| queue.to_s.strip }.presence || [ "*" ]
      @relation = relation
    end

    def scoped_relations
      if queue_names.empty? then [ relation.all ]
      else
        queue_names.map { |queue_name| relation.queued_as(queue_name) }
      end
    end

    private
      def queue_names
        if all? then filter_paused_queues
        else
          filter_paused_queues(exact_names)
        end
      end

      def all?
        "*".in? raw_queues
      end

      def filter_paused_queues(queues = [])
        paused_queues = Pause.all_queue_names
        if paused_queues.empty? then queues
        else
          queues = queues.presence || Queue.all.map(&:name)
          queues - paused_queues
        end
      end

      def exact_names
        @exact_names ||= raw_queues.select { |queue| !queue.include?("*") }
      end
  end
end
