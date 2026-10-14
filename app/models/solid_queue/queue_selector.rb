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
          in_raw_order(exact_names + prefixed_names)
        end
      end

      def include_all_queues?
        "*".in? raw_queues
      end

      def all_queues
        relation.distinct_values_of(:queue_name)
      end

      def exact_names
        raw_queues.select { |queue| exact_name?(queue) }
      end

      def prefixed_names
        if prefixes.empty? then []
        else
          pattern = "queue_name LIKE ? #{like_escape_clause}"
          relation.where(([ pattern ] * prefixes.count).join(" OR "), *prefixes).distinct_values_of(:queue_name)
        end
      end

      # MySQL string literals treat a backslash as an escape, so the single-character
      # ESCAPE value is written with a doubled backslash. SQLite and PostgreSQL take one.
      def like_escape_clause
        if relation.connection.adapter_name.match?(/mysql|trilogy/i)
          "ESCAPE '\\\\'"
        else
          "ESCAPE '\\'"
        end
      end

      def prefixes
        @prefixes ||= raw_queues.select { |queue| prefixed_name?(queue) }.map { |queue| relation.sanitize_sql_like(queue).tr("*", "%") }
      end

      def exact_name?(queue)
        !queue.include?("*")
      end

      def prefixed_name?(queue)
        queue.ends_with?("*")
      end

      def paused_queues
        @paused_queues ||= Pause.all.pluck(:queue_name)
      end

      def in_raw_order(queues)
        # Exact names are already in configuration order. Prefix matches always
        # go through the literal filter so a single false LIKE hit is not returned.
        if prefixes.empty?
          queues
        else
          queues = queues.dup
          raw_queues.flat_map { |raw_queue| delete_in_order(raw_queue, queues) }.compact
        end
      end

      def delete_in_order(raw_queue, queues)
        if exact_name?(raw_queue)
          queues.delete(raw_queue)
        elsif prefixed_name?(raw_queue)
          prefix = raw_queue.tr("*", "")
          queues.select { |queue| queue.start_with?(prefix) }.tap do |matches|
            queues -= matches
          end
        end
      end
  end
end
