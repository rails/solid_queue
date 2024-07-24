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
        configured_process.supervised_by process
        configured_process.start

        threads[configured_process.name] = configured_process
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
