# frozen_string_literal: true

module SolidQueue
  class Worker < Processes::Poller
    include LifecycleHooks

    after_boot :run_start_hooks
    before_shutdown :run_stop_hooks
    after_shutdown :run_exit_hooks

    attr_reader :queues, :pool

    def initialize(**options)
      options = options.dup
      validate_execution_options!(options)

      execution_pool_type = options.key?(:fibers) ? :fiber : :thread
      execution_pool_size = options[:fibers] || options[:threads] || SolidQueue::Configuration::WORKER_DEFAULTS[:threads]
      options = options.with_defaults(worker_defaults_for(options))

      # Ensure that the queues array is deep frozen to prevent accidental modification
      @queues = Array(options[:queues]).map(&:freeze).freeze
      @metadata_state_mutex = Mutex.new
      @metadata_dirty = false

      @pool_options = {
        type: execution_pool_type,
        size: execution_pool_size,
        on_state_change: -> { mark_metadata_dirty; wake_up }
      }

      super(**options)
    end

    def metadata
      super.merge(queues: queues.join(",")).merge(pool.metadata)
    end

    private
      def poll
        claim_executions.then do |executions|
          executions.each do |execution|
            pool.post(execution)
          end

          reload_metadata_if_needed(executions.any?)

          pool.idle? ? polling_interval : 10.minutes
        end
      end

      def claim_executions
        with_polling_volume do
          SolidQueue::ReadyExecution.claim(queues, pool.available_capacity, process_id)
        end
      end

      def boot
        build_pool
        super
      end

      def shutdown
        pool.shutdown
        pool.wait_for_termination(SolidQueue.shutdown_timeout)

        super
      end

      def all_work_completed?
        SolidQueue::ReadyExecution.aggregated_count_across(queues).zero?
      end

      def heartbeat
        super
        reload_metadata
      end

      def set_procline
        procline "waiting for jobs in #{queues.join(",")}"
      end

      def build_pool
        @pool ||= ExecutionPools.build(**@pool_options)
      end

      def validate_execution_options!(options)
        if options.key?(:threads) && options.key?(:fibers)
          raise ArgumentError, "Workers can specify either `threads` or `fibers`, but not both."
        end
      end

      def worker_defaults_for(options)
        if options.key?(:fibers)
          SolidQueue::Configuration::WORKER_DEFAULTS.except(:threads)
        else
          SolidQueue::Configuration::WORKER_DEFAULTS
        end
      end

      def mark_metadata_dirty
        metadata_state_mutex.synchronize { @metadata_dirty = true }
      end

      def metadata_state_mutex
        @metadata_state_mutex
      end

      def reload_metadata_if_needed(executions_claimed)
        needs_reload = metadata_state_mutex.synchronize do
          claimed_or_dirty = executions_claimed || @metadata_dirty
          @metadata_dirty = false
          claimed_or_dirty
        end

        reload_metadata if needs_reload
      end
  end
end
