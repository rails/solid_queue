# frozen_string_literal: true

module SolidQueue
  class Worker < Processes::Poller
    include LifecycleHooks
    include Processes::Recyclable

    after_boot :run_start_hooks
    before_shutdown :run_stop_hooks

    attr_accessor :queues, :pool

    def initialize(**options)
      options = options.dup.with_defaults(SolidQueue::Configuration::WORKER_DEFAULTS)
      recyclable_setup(**options)

      @queues = Array(options[:queues])
      @pool = Pool.new(options[:threads], on_idle: -> { wake_up })

      super(**options)
    end

    def metadata
      super.then { _1.merge(queues: queues.join(","), thread_pool_size: pool.size) }
           .then { oom_configured? ? _1.merge(recycle_on_oom: max_memory) : _1 }
    end

    private
      def poll
        claim_executions.then do |executions|
          executions.each do |execution|
            pool.post(execution, self)
          end

          executions.size
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
