# frozen_string_literal: true

module SolidQueue
  class Supervisor < Processes::Base
    include Maintenance, Signals, Pidfiled

    class << self
      def start(mode: "fork", load_configuration_from: nil, **options)
        SolidQueue.supervisor = true
        configuration = Configuration.new(mode: mode, load_from: load_configuration_from)

        if configuration.configured_processes.any?
          klass = mode.to_s.inquiry.fork? ? ForkSupervisor : AsyncSupervisor
          klass.new(configuration, **options).tap(&:start)
        else
          abort "No workers or processed configured. Exiting..."
        end
      end
    end

    def initialize(configuration, **options)
      @configuration = configuration
      super
    end

    def start
      boot

      start_processes
      launch_maintenance_task

      supervise
    end

    def stop
      @stopped = true
    end

    private
      attr_reader :configuration

      def boot
        SolidQueue.instrument(:start_process, process: self) do
          run_callbacks(:boot) do
            @stopped = false
            sync_std_streams
          end
        end
      end

      def start_processes
        configuration.configured_processes.each { |configured_process| start_process(configured_process) }
      end

      def stopped?
        @stopped
      end

      def set_procline
        procline "supervising #{supervised_processes.join(", ")}"
      end

      def start_process(configured_process)
        raise NotImplementedError
      end

      def terminate_gracefully
        SolidQueue.instrument(:graceful_termination, process_id: process_id, supervisor_pid: ::Process.pid, supervised_processes: supervised_processes) do |payload|
          perform_graceful_termination

          unless all_processes_terminated?
            payload[:shutdown_timeout_exceeded] = true
            terminate_immediately
          end
        end
      end

      def terminate_immediately
        SolidQueue.instrument(:immediate_termination, process_id: process_id, supervisor_pid: ::Process.pid, supervised_processes: supervised_processes) do
          perform_immediate_termination
        end
      end

      def perform_graceful_termination
        raise NotImplementedError
      end

      def perform_immediate_termination
        raise NotImplementedError
      end

      def supervised_processes
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

      def sync_std_streams
        STDOUT.sync = STDERR.sync = true
      end
  end
end
