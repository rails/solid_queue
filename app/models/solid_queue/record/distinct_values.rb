# frozen_string_literal: true

module SolidQueue
  class Record
    module DistinctValues
      extend ActiveSupport::Concern

      # PostgreSQL has no native loose index scan, so a plain DISTINCT on a leading
      # index column degrades to a full index scan on large tables. We emulate one
      # with a recursive CTE that walks the index jumping between distinct values.
      class_methods do
        def distinct_values_of(column)
          if loose_index_scan_emulation_needed?
            loose_distinct_via_recursive_cte(column)
          else
            distinct.pluck(column)
          end
        end

        private
          def loose_index_scan_emulation_needed?
            connection.adapter_name == "PostgreSQL"
          end

          # Emulates a loose index scan, honoring the current scope (e.g. LIKE prefixes)
          # by building the anchor and the recursive step as scoped relations, whose
          # #to_sql inlines any bind parameters so they can be embedded in the raw CTE.
          def loose_distinct_via_recursive_cte(column)
            col = connection.quote_column_name(column)

            connection.select_values(<<~SQL.squish)
              WITH RECURSIVE t AS (
                (#{next_distinct_value(col, "#{col} IS NOT NULL")})
                UNION ALL
                SELECT (#{next_distinct_value(col, "#{col} > t.#{col}")}) FROM t WHERE t.#{col} IS NOT NULL
              )
              SELECT #{col} FROM t WHERE #{col} IS NOT NULL
            SQL
          end

          # Smallest value of `col` within the current scope that matches `condition`.
          def next_distinct_value(col, condition)
            all.where(Arel.sql(condition)).reorder(Arel.sql(col)).limit(1).select(Arel.sql(col)).to_sql
          end
      end
    end
  end
end
