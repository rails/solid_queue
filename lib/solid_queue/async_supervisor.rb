module SolidQueue
  class AsyncSupervisor
    class << self
      def load(load_configuration_from: nil)
        configuration = Configuration.new(mode: :async, load_from: load_configuration_from)
        new(*configuration.processes)
      end
    end

    def initialize(*configured_processes)
      @configured_processes = Array(configured_processes)
    end

    def start
      @configured_processes.each(&:start)
    end

    def stop
      @configured_processes.each(&:stop)
    end
  end
end
