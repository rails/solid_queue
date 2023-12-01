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
          filter_paused_queues(exact_names + prefixed_names)
        end
      end

      def all?
        "*".in? raw_queues
      end

      def filter_paused_queues(queues = [])
        paused_queues = Pause.all.pluck(:queue_name)

        if paused_queues.empty? then queues
        else
          queues = queues.presence || all_queue_names
          queues - paused_queues
        end
      end

      def exact_names
        @exact_names ||= raw_queues.select { |queue| !queue.include?("*") }
      end

      def prefixed_names
        if prefixes.empty? then []
        else
          relation.where(([ "queue_name LIKE ?" ] * prefixes.count).join(" OR "), *prefixes).distinct(:queue_name).pluck(:queue_name)
        end
      end

      def prefixes
        @prefixes ||= raw_queues.select { |queue| queue.ends_with?("*") }.map { |queue| queue.tr("*", "%") }
      end

      def all_queue_names
        relation.distinct(:queue_name).pluck(:queue_name)
      end
  end
end
