# frozen_string_literal: true

module SolidQueue
  class FailedExecution < Execution
    include Dispatching

    serialize :error, coder: JSON

    before_create :expand_error_details_from_exception

    attr_accessor :exception

    def self.retry_all(jobs)
      SolidQueue.instrument(:retry_all, jobs_size: jobs.size) do |payload|
        transaction do
          payload[:size] = dispatch_jobs lock_all_from_jobs(jobs)
        end
      end
    end

    def retry
      SolidQueue.instrument(:retry, job_id: job.id) do
        with_lock do
          job.reset_execution_counters
          job.prepare_for_execution
          destroy!
        end
      end
    end

    %i[ exception_class message backtrace ].each do |attribute|
      define_method(attribute) { error.with_indifferent_access[attribute] }
    end

    private
      JSON_OVERHEAD = 256
      DEFAULT_BACKTRACE_LINES_LIMIT = 400

      def expand_error_details_from_exception
        if exception
          self.error = { exception_class: exception_class_name, message: exception_message, backtrace: exception_backtrace }
        end
      end

      def exception_class_name
        exception.class.name
      end

      def exception_message
        exception.message
      end

      def exception_backtrace
        if column = self.class.connection.schema_cache.columns_hash(self.class.table_name)["error"]
          limit = column.limit - exception_class_name.bytesize - exception_message.bytesize - JSON_OVERHEAD

          if exception.backtrace.to_json.bytesize <= limit
            exception.backtrace
          else
            truncate_backtrace(exception.backtrace, limit)
          end
        else
          exception.backtrace.take(DEFAULT_BACKTRACE_LINES_LIMIT)
        end
      end

      def truncate_backtrace(lines, limit)
        [].tap do |truncated_backtrace|
          lines.each do |line|
            if (truncated_backtrace << line).to_json.bytesize > limit
              truncated_backtrace.pop
              break
            end
          end
        end
      end
  end
end
