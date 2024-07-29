# frozen_string_literal: true

module SolidQueue
  class Supervisor < Processes::Base
    include Maintenance

    class << self
      def start(mode: :fork, load_configuration_from: nil)
        SolidQueue.supervisor = true
        configuration = Configuration.new(mode: mode, load_from: load_configuration_from)

        klass = mode == :fork ? ForkSupervisor : AsyncSupervisor
        klass.new(configuration).tap(&:start)
      end
    end

    def initialize(configuration)
      @configuration = configuration
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
        configuration.processes.each { |configured_process| start_process(configured_process) }
      end

      def stopped?
        @stopped
      end

      def supervise
      end

      def start_process(configured_process)
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
