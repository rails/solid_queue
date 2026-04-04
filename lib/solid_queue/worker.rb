# frozen_string_literal: true

module SolidQueue
  class Worker < Processes::Poller
    include LifecycleHooks

    after_boot :run_start_hooks
    before_shutdown :run_stop_hooks
    after_shutdown :run_exit_hooks

    attr_reader :queues, :execution_backend, :concurrency_model, :fibers, :threads

    alias pool execution_backend

    def initialize(**options)
      options = options.dup.with_defaults(SolidQueue::Configuration::WORKER_DEFAULTS)

      # Ensure that the queues array is deep frozen to prevent accidental modification
      @queues = Array(options[:queues]).map(&:freeze).freeze
      @threads = options[:threads]
      @concurrency_model = options[:concurrency_model].to_s.inquiry
      @fibers = options[:fibers]

      ensure_supported_concurrency_model!

      @execution_backend = build_execution_backend(options)

      super(**options)
    end

    def metadata
      super.merge(queues: queues.join(","), thread_pool_size: threads, concurrency_model: concurrency_model.to_s).tap do |metadata|
        metadata[:fiber_pool_size] = fibers if fibers.present?
        metadata[:execution_capacity] = execution_backend.capacity if concurrency_model.fiber?
      end
    end

    private
      def ensure_supported_concurrency_model!
        return if concurrency_model.thread? || concurrency_model.fiber?

        raise ArgumentError, "Unsupported worker concurrency model: #{concurrency_model}"
      end

      def build_execution_backend(options)
        if concurrency_model.fiber?
          FiberPool.new(options[:threads], options[:fibers], on_available: -> { wake_up }, name: name)
        else
          Pool.new(options[:threads], on_available: -> { wake_up })
        end
      end

      def poll
        claim_executions.then do |executions|
          executions.each do |execution|
            execution_backend.post(execution)
          end

          execution_backend.available? ? polling_interval : 10.minutes
        end
      end

      def claim_executions
        with_polling_volume do
          SolidQueue::ReadyExecution.claim(queues, execution_backend.available_capacity, process_id)
        end
      end

      def shutdown
        execution_backend.shutdown
        execution_backend.wait_for_termination(SolidQueue.shutdown_timeout)

        super
      end

      def all_work_completed?
        SolidQueue::ReadyExecution.aggregated_count_across(queues).zero?
      end

      def set_procline
        procline "waiting for jobs in #{queues.join(",")}"
      end
  end
end
