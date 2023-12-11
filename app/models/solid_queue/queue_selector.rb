# frozen_string_literal: true

module SolidQueue
  class QueueSelector
    attr_reader :raw_queues, :relation

    def initialize(queue_list, relation)
      @raw_queues = Array(queue_list).map { |queue| queue.to_s.strip }.presence || [ "*" ]
      @relation = relation
    end

    def scoped_relations
      case
      when all?  then [ relation.all ]
      when none? then [ relation.none ]
      else
        queue_names.map { |queue_name| relation.queued_as(queue_name) }
      end
    end

    private
      def all?
        include_all_queues? && paused_queues.empty?
      end

      def none?
        queue_names.empty?
      end

      def queue_names
        @queue_names ||= eligible_queues - paused_queues
      end

      def eligible_queues
        if include_all_queues? then all_queues
        else
          exact_names + prefixed_names
        end
      end

      def include_all_queues?
        "*".in? raw_queues
      end

      def exact_names
        raw_queues.select { |queue| !queue.include?("*") }
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

      def all_queues
        relation.distinct(:queue_name).pluck(:queue_name)
      end

      def paused_queues
        @paused_queues ||= Pause.all.pluck(:queue_name)
      end
  end
end
