# frozen_string_literal: true

module SolidQueue
  class Supervisor < Processes::Base
    include LifecycleHooks
    include Maintenance, Signals, Pidfiled

    after_shutdown :run_exit_hooks

    class << self
      def start(**options)
        SolidQueue.supervisor = true
        configuration = Configuration.new(**options)

        if configuration.valid?
          klass = configuration.mode.fork? ? ForkSupervisor : AsyncSupervisor
          klass.new(configuration).tap(&:start)
        else
          abort configuration.errors.full_messages.join("\n") + "\nExiting..."
        end
      end
    end

    def initialize(configuration)
      @configuration = configuration
      super
    end

    def start
      boot
      run_start_hooks

      start_processes
      launch_maintenance_task

      supervise
    end

    def stop
      super
      run_stop_hooks
    end

    private
      attr_reader :configuration

      def boot
        SolidQueue.instrument(:start_process, process: self) do
          run_callbacks(:boot) do
            sync_std_streams
          end
        end
      end

      def supervise
        loop do
          break if stopped?

          set_procline
          process_signal_queue

          unless stopped?
            reap_and_replace_terminated_forks
            interruptible_sleep(1.second)
          end
        end
      ensure
        shutdown
      end

      def start_processes
        raise NotImplementedError
      end

      def set_procline
        procline "supervising #{supervised_processes.join(", ")}"
      end

      def shutdown
        SolidQueue.instrument(:shutdown_process, process: self) do
          run_callbacks(:shutdown) do
            stop_maintenance_task
          end
        end
      end

      def sync_std_streams
        STDOUT.sync = STDERR.sync = true
      end

      def reap_and_replace_terminated_forks
        # No-op by default, implemented in ForkSupervisor
      end
  end
end