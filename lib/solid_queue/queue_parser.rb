# frozen_string_literal: true

module SolidQueue
  class QueueParser
    attr_reader :raw_queues, :relation

    def initialize(queue_list, relation)
      @raw_queues = Array(queue_list).map(&:strip).presence || [ "*" ]
      @relation = relation
    end

    def scoped_relation
      if all? then relation.all
      else
        by_exact_names.or(by_prefixes)
      end
    end

    private
      def all?
        "*".in? raw_queues
      end

      def by_exact_names
        exact_names.any? ? relation.where(queue_name: exact_names) : relation.none
      end

      def by_prefixes
        prefixes.any? ? relation.where(([ "queue_name LIKE ?" ] * prefixes.count).join(" OR "), *prefixes) : relation.none
      end

      def exact_names
        @exact_names ||= raw_queues.select { |queue| !queue.include?("*") }
      end

      def prefixes
        @prefixes ||= raw_queues.select { |queue| queue.ends_with?("*") }.map { |queue| queue.tr("*", "%") }
      end
  end
end
