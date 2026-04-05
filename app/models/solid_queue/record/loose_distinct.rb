# frozen_string_literal: true

module SolidQueue
  class Record
    module LooseDistinct
      extend ActiveSupport::Concern

      class_methods do
        def distinct_values_of(column, like_conditions: [])
          if postgresql?
            loose_distinct_via_recursive_cte(column, like_conditions)
          elsif like_conditions.any?
            where(like_sql(column, like_conditions)).distinct.pluck(column)
          else
            distinct.pluck(column)
          end
        end

        private
          def loose_distinct_via_recursive_cte(column, like_conditions)
            table = quoted_table_name
            col = connection.quote_column_name(column)

            like_filter = if like_conditions.any?
              "AND (" + like_conditions.map { |pattern| sanitize_sql_array([ "#{col} LIKE ?", pattern ]) }.join(" OR ") + ")"
            end

            sql = <<~SQL.squish
              WITH RECURSIVE t AS (
                (SELECT #{col} FROM #{table} WHERE #{col} IS NOT NULL #{like_filter} ORDER BY #{col} LIMIT 1)
                UNION ALL
                SELECT (SELECT #{col} FROM #{table} WHERE #{col} > t.#{col} #{like_filter} ORDER BY #{col} LIMIT 1)
                FROM t WHERE t.#{col} IS NOT NULL
              )
              SELECT #{col} FROM t WHERE #{col} IS NOT NULL
            SQL

            connection_pool.with_connection { |conn| conn.select_values(sql) }
          end

          def like_sql(column, patterns)
            col = connection.quote_column_name(column)
            ([ "#{col} LIKE ?" ] * patterns.count).join(" OR ").then { |clause| [ clause, *patterns ] }
          end

          def postgresql?
            connection_pool.with_connection { |conn| conn.adapter_name == "PostgreSQL" }
          end
      end
    end
  end
end
