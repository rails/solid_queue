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

    delegate :mode, :standalone?, to: :configuration

    def initialize(configuration)
      @configuration = configuration

      @configured_processes = {}
      @process_instances = {}

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

    def kind
      "Supervisor(#{mode})"
    end

    private
      attr_reader :configuration, :configured_processes, :process_instances

      def boot
        SolidQueue.instrument(:start_process, process: self) do
          run_callbacks(:boot) do
            sync_std_streams
          end
        end
      end

      def start_processes
        configuration.configured_processes.each { |configured_process| start_process(configured_process) }
      end

      def supervise
        loop do
          break if stopped?

          if standalone?
            set_procline
            process_signal_queue
          end

          unless stopped?
            check_and_replace_terminated_processes
            interruptible_sleep(1.second)
          end
        end
      ensure
        shutdown
      end

      def start_process(configured_process)
        process_instance = configured_process.instantiate.tap do |instance|
          instance.supervised_by process
          instance.mode = mode
        end

        process_id = process_instance.start

        configured_processes[process_id] = configured_process
        process_instances[process_id] = process_instance
      end

      def check_and_replace_terminated_processes
      end

      def terminate_gracefully
        SolidQueue.instrument(:graceful_termination, process_id: process_id, supervisor_pid: ::Process.pid, supervised_processes: configured_processes.keys) do |payload|
          perform_graceful_termination

          unless all_processes_terminated?
            payload[:shutdown_timeout_exceeded] = true
            terminate_immediately
          end
        end
      end

      def terminate_immediately
        SolidQueue.instrument(:immediate_termination, process_id: process_id, supervisor_pid: ::Process.pid, supervised_processes: configured_processes.keys) do
          perform_immediate_termination
        end
      end

      def perform_graceful_termination
        raise NotImplementedError
      end

      def perform_immediate_termination
        raise NotImplementedError
      end

      def all_processes_terminated?
        raise NotImplementedError
      end

      def shutdown
        SolidQueue.instrument(:shutdown_process, process: self) do
          run_callbacks(:shutdown) do
            stop_maintenance_task
          end
        end
      end

      def set_procline
        procline "supervising #{configured_processes.keys.join(", ")}"
      end

      def sync_std_streams
        STDOUT.sync = STDERR.sync = true
      end
  end
end
