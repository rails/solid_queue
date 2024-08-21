# frozen_string_literal: true

module SolidQueue
  class Supervisor::AsyncSupervisor < Supervisor
    def initialize(*)
      super
      @threads = Concurrent::Map.new
    end

    def kind
      "Supervisor(async)"
    end

    def stop
      super
      stop_threads
      threads.clear

      shutdown
    end

    private
      attr_reader :threads

      def start_process(configured_process)
        process_instance = configured_process.instantiate.tap do |instance|
          instance.supervised_by process
        end

        process_instance.start

        threads[process_instance.name] = process_instance
      end

      def stop_threads
        stop_threads = threads.values.map do |thr|
          Thread.new { thr.stop }
        end

        stop_threads.each { |thr| thr.join(SolidQueue.shutdown_timeout) }
      end

      def all_threads_terminated?
        threads.values.none?(&:alive?)
      end
  end
end
