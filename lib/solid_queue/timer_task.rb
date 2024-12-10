# frozen_string_literal: true

module SolidQueue
  class TimerTask
    include AppExecutor

    def initialize(execution_interval:, run_now: false, &block)
      raise ArgumentError, "A block is required" unless block_given?
      @shutdown = Concurrent::AtomicBoolean.new

      run(run_now, execution_interval, &block)
    end

    def shutdown
      @shutdown.make_true
    end

    private

      def run(run_now, execution_interval, &block)
        execute_task(&block) if run_now

        Concurrent::Promises.future(execution_interval) do |interval|
          repeating_task(interval, &block)
        end.run
      end

      def execute_task(&block)
        block.call unless @shutdown.true?
      rescue Exception => e
        handle_thread_error(e)
      end

      def repeating_task(interval, &block)
        Concurrent::Promises.schedule(interval) do
          execute_task(&block)
        end.then do
          repeating_task(interval, &block) unless @shutdown.true?
        end
      end
  end
end
