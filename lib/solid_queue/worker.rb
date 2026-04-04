# frozen_string_literal: true

module SolidQueue
  class Worker < Processes::Poller
    include LifecycleHooks

    CONCURRENCY_MODE_NOT_IMPLEMENTED_MESSAGE = "Worker `concurrency_model: fiber` is not implemented yet".freeze

    after_boot :run_start_hooks
    before_shutdown :run_stop_hooks
    after_shutdown :run_exit_hooks

    attr_reader :queues, :pool, :concurrency_model, :fibers

    def initialize(**options)
      options = options.dup.with_defaults(SolidQueue::Configuration::WORKER_DEFAULTS)

      # Ensure that the queues array is deep frozen to prevent accidental modification
      @queues = Array(options[:queues]).map(&:freeze).freeze
      @concurrency_model = options[:concurrency_model].to_s.inquiry
      @fibers = options[:fibers]

      ensure_supported_concurrency_model!

      @pool = Pool.new(options[:threads], on_idle: -> { wake_up })

      super(**options)
    end

    def metadata
      super.merge(queues: queues.join(","), thread_pool_size: pool.size, concurrency_model: concurrency_model.to_s).tap do |metadata|
        metadata[:fiber_pool_size] = fibers if fibers.present?
      end
    end

    private
      def ensure_supported_concurrency_model!
        raise NotImplementedError, CONCURRENCY_MODE_NOT_IMPLEMENTED_MESSAGE if concurrency_model.fiber?
      end

      def poll
        claim_executions.then do |executions|
          executions.each do |execution|
            pool.post(execution)
          end

          pool.idle? ? polling_interval : 10.minutes
        end
      end

      def claim_executions
        with_polling_volume do
          SolidQueue::ReadyExecution.claim(queues, pool.idle_threads, process_id)
        end
      end

      def shutdown
        pool.shutdown
        pool.wait_for_termination(SolidQueue.shutdown_timeout)

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
