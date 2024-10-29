# frozen_string_literal: true

module SolidQueue
  class Queue
    attr_accessor :name

    class << self
      def all
        queue_names.collect do |queue_name|
          new(queue_name)
        end
      end

      def find_by_name(name)
        new(name)
      end

      private

      def queue_names
        # PostgreSQL doesn't perform well with SELECT DISTINCT
        # => Use recursive common table expressions if possible for better performance (https://wiki.postgresql.org/wiki/Loose_indexscan)
        if SolidQueue::Record.connection.adapter_name.downcase == "postgresql" && SolidQueue::Record.connection.supports_common_table_expressions?
          Job.connection.execute(queue_names_recursive_cte_sql).to_a.map { |row| row["queue_name"] }
        else
          Job.select(:queue_name).distinct.map(&:queue_name)
        end
      end

      def queue_names_recursive_cte_sql
        # This relies on the fact that queue_name in solid_queue_jobs is NOT NULL
        # The sql looks something like below:
        # WITH RECURSIVE t AS (
        #   (SELECT queue_name FROM solid_queue_jobs ORDER BY queue_name LIMIT 1)  -- parentheses required
        #   UNION ALL
        #   SELECT (SELECT queue_name FROM solid_queue_jobs WHERE queue_name > t.queue_name ORDER BY queue_name LIMIT 1)
        #   FROM t
        #   WHERE t.queue_name IS NOT NULL
        # )
        # SELECT queue_name FROM t WHERE queue_name IS NOT NULL;

        cte_table = Arel::Table.new(:t)
        jobs_table = Job.arel_table

        cte_base_case = jobs_table.project(jobs_table[:queue_name]).order(jobs_table[:queue_name]).take(1)

        subquery = jobs_table
          .project(jobs_table[:queue_name])
          .where(jobs_table[:queue_name].gt(cte_table[:queue_name]))
          .order(jobs_table[:queue_name])
          .take(1)
        cte_recursive_case = cte_table.project(subquery)
          .where(cte_table[:queue_name].not_eq(nil))

        cte_definition = Arel::Nodes::Cte.new(
          Arel.sql("t"),
          Arel::Nodes::UnionAll.new(cte_base_case, cte_recursive_case),
        )

        cte_table
          .project(cte_table[:queue_name])
          .where(cte_table[:queue_name].not_eq(nil))
          .with(:recursive, cte_definition)
          .to_sql
      end
    end

    def initialize(name)
      @name = name
    end

    def paused?
      Pause.exists?(queue_name: name)
    end

    def pause
      Pause.create_or_find_by!(queue_name: name)
    end

    def resume
      Pause.where(queue_name: name).delete_all
    end

    def clear
      ReadyExecution.queued_as(name).discard_all_in_batches
    end

    def size
      @size ||= ReadyExecution.queued_as(name).count
    end

    def ==(queue)
      name == queue.name
    end
    alias_method :eql?, :==

    def hash
      name.hash
    end
  end
end
