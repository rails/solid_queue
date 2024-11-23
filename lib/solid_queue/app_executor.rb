# frozen_string_literal: true

module SolidQueue
  module AppExecutor
    def wrap_in_app_executor(&block)
      if SolidQueue.app_executor
        SolidQueue.app_executor.wrap(&block)
      else
        yield
      end
    end

    def handle_thread_error(error)
      CallErrorReporters.new(error).call
    end

    private

      # Handles error reporting and guarantees that Rails.error will be called if configured.
      #
      # This method performs the following actions:
      # 1. Invokes `SolidQueue.instrument` for `:thread_error`.
      # 2. Invokes `SolidQueue.on_thread_error` if it is configured.
      # 3. Invokes `Rails.error.report` if it wasn't invoked by one of the above calls.
      class CallErrorReporters
        # @param [Exception] error The error to be reported.
        def initialize(error)
          @error = error
          @reported = false
        end

        def call
          SolidQueue.instrument(:thread_error, error: @error)
          Rails.error.subscribe(self) if Rails.error&.respond_to?(:subscribe)

          SolidQueue.on_thread_error&.call(@error)

          Rails.error.report(@error, handled: false, source: SolidQueue.reporting_label) unless @reported
        ensure
          Rails.error.unsubscribe(self) if Rails.error&.respond_to?(:unsubscribe)
        end

        def report(*, **)
          @reported = true
        end
      end
  end
end
