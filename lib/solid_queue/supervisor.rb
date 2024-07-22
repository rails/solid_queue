# frozen_string_literal: true

module SolidQueue
  class Supervisor < Processes::Base
    include Maintenance

    class GracefulTerminationRequested < Interrupt; end
    class ImmediateTerminationRequested < Interrupt; end

    class << self
      def start(mode: :fork, load_configuration_from: nil)
        SolidQueue.supervisor = true
        configuration = Configuration.new(load_from: load_configuration_from)

        Forks.new(configuration).start
      end
    end

    def initialize(configuration)
      @configuration = configuration
    end

    def start
      run_callbacks(:boot) { boot }

      start_processes
      launch_maintenance_task

      supervise
    rescue GracefulTerminationRequested
      terminate_gracefully
    rescue ImmediateTerminationRequested
      terminate_immediately
    ensure
      run_callbacks(:shutdown) { shutdown }
    end

    private
      attr_reader :configuration

      def boot
        sync_std_streams
      end

      def start_processes
        configuration.processes.each { |configured_process| start_process(configured_process) }
      end

      def supervise
        raise NotImplementedError
      end

      def start_process(configured_process)
        raise NotImplementedError
      end

      def terminate_gracefully
      end

      def terminate_immediately
      end

      def shutdown
        stop_maintenance_task
      end

      def sync_std_streams
        STDOUT.sync = STDERR.sync = true
      end
  end
end
