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
          configuration.warnings.full_messages.each { |warning| SolidQueue.logger.warn(warning) }

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

      if stopped?
        shutdown
      else
        launch_maintenance_task
        supervise
      end
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
        configuration.configured_processes.each do |configured_process|
          # Honour signals that arrive during boot or start hooks: a queued TERM
          # stops us here, before starting children, instead of in #supervise,
          # after all of them have been started
          break if time_to_stop?

          start_process(configured_process)
        end
      end

      def supervise
        until time_to_stop?
          set_procline
          check_and_replace_terminated_processes
          interruptible_sleep(1.second)
        end
      ensure
        shutdown
      end

      # Process any signals queued while we were busy and report whether
      # we've been asked to stop
      def time_to_stop?
        process_signal_queue
        stopped?
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
        # Embedded supervisors don't own their process's title
        if standalone?
          procline "supervising #{configured_processes.keys.join(", ")}"
        end
      end

      def sync_std_streams
        STDOUT.sync = STDERR.sync = true
      end
  end
end
