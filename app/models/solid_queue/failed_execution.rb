# frozen_string_literal: true

module SolidQueue
  class FailedExecution < Execution
    include Dispatching, Batchable

    serialize :error, coder: JSON

    before_save :expand_error_details_from_exception, if: :exception

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
      TRUNCATED_MESSAGE_OMISSION = "... (truncated)"

      def expand_error_details_from_exception
        if exception
          self.error = fit_into_error_column(exception_class: exception_class_name, message: exception_message, backtrace: exception_backtrace)
        end
      end

      def exception_class_name
        exception.class.name
      end

      def exception_message
        exception.message
      end

      def exception_backtrace
        exception.backtrace
      end

      # Columns with a size limit, like MySQL's TEXT, reject (or truncate into invalid JSON)
      # errors that don't fit. Drop backtrace lines first and, if that's not enough, cut the
      # message, measuring the error as it'll be stored, after JSON escaping.
      def fit_into_error_column(error)
        if (limit = error_column_limit) && serialized_error_size(error) > limit
          error[:backtrace] = truncate_backtrace(error, limit) if error[:backtrace]
          error[:message] = truncate_message(error, limit) if serialized_error_size(error) > limit
        end

        error
      end

      def error_column_limit
        column = self.class.connection_pool.with_connection do |connection|
          connection.schema_cache.columns_hash(self.class.table_name)["error"]
        end

        column&.limit
      end

      def serialized_error_size(error)
        self.class.type_for_attribute(:error).serialize(error).bytesize
      end

      def truncate_backtrace(error, limit)
        # Each kept line adds its own encoded size plus a separating comma
        available = limit - serialized_error_size(error.merge(backtrace: [])) + 1

        error[:backtrace].take_while do |line|
          (available -= serialized_error_size(line) + 1) >= 0
        end
      end

      def truncate_message(error, limit)
        message = error[:message].to_s

        # Every byte cut from the message shrinks its encoded size by at least one byte,
        # so cutting the overflow converges in very few iterations, even with escaping
        while message.present? && (overflow = serialized_error_size(error.merge(message: message)) - limit) > 0
          truncate_to = message.bytesize - overflow

          message = if truncate_to > TRUNCATED_MESSAGE_OMISSION.bytesize
            message.truncate_bytes(truncate_to, omission: TRUNCATED_MESSAGE_OMISSION)
          else
            ""
          end
        end

        message
      end
  end
end
