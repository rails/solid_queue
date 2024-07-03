# frozen_string_literal: true

module SolidQueue
  class Supervisor < Processes::Base
    include Signals, Maintenance

    class << self
      def start(mode: :fork, load_configuration_from: nil)
        SolidQueue.supervisor = true
        configuration = Configuration.new(load_from: load_configuration_from)

        Forks.new(configuration).start
      end
    end

    def initialize(configuration)
      @configuration = configuration
      @processes = {}
    end

    def start
      run_callbacks(:boot) { boot }

      start_processes
      launch_maintenance_task

      supervise
    rescue GracefulTerminationRequested
      terminate_gracefully
    rescue ImmediateTerminationRequested
      immediate_termination
    ensure
      run_callbacks(:shutdown) { shutdown }
    end

    private
      attr_reader :configuration, :processes

      def boot
        sync_std_streams
        setup_pidfile
        register_signal_handlers
      end

      def start_processes
        configuration.processes.each { |configured_process| start_process(configured_process) }
      end

      def supervise
        loop do
          procline "supervising #{processes.keys.join(", ")}"

          process_signal_queue
          reap_and_replace_terminated_processes
          interruptible_sleep(1.second)
        end
      end


      def sync_std_streams
        STDOUT.sync = STDERR.sync = true
      end

      def setup_pidfile
        if path = SolidQueue.supervisor_pidfile
          @pidfile = Pidfile.new(path).tap(&:setup)
        end
      end


      def start_process(configured_process)
        raise NotImplementedError
      end


      def shutdown
        stop_maintenance_task
        restore_default_signal_handlers
        delete_pidfile
      end

      def terminate_gracefully
        SolidQueue.instrument(:graceful_termination, supervisor_pid: ::Process.pid, supervised_processes: processes.keys) do |payload|
          term_processes

          Timer.wait_until(SolidQueue.shutdown_timeout, -> { all_processes_terminated? }) do
            reap_terminated_processes
          end

          unless all_processes_terminated?
            payload[:shutdown_timeout_exceeded] = true
            immediate_termination
          end
        end
      end

      def immediate_termination
        SolidQueue.instrument(:immediate_termination, supervisor_pid: ::Process.pid, supervised_processes: processes.keys) do
          quit_processes
        end
      end

      def delete_pidfile
        @pidfile&.delete
      end
  end
end
