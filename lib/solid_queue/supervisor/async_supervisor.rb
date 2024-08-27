# frozen_string_literal: true

module SolidQueue
  class Supervisor::AsyncSupervisor < Supervisor
    skip_callback :boot, :before, :register_signal_handlers, unless: :standalone?

    def initialize(*, standalone: true)
      super

      @standalone = standalone
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

      def standalone?
        @standalone
      end

      def start_process(configured_process)
        process_instance = configured_process.instantiate.tap do |instance|
          instance.supervised_by process
        end

        process_instance.start
        threads[process_instance.name] = process_instance
      end

      def supervised_processes
        threads.keys
      end

      def supervise
        if standalone?
          loop do
            break if stopped?

            set_procline
            process_signal_queue

            interruptible_sleep(10.second) unless stopped?
          end
        end
      end

      def stop_threads
        stop_threads = threads.values.map do |thr|
          Thread.new { thr.stop }
        end

        stop_threads.each { |thr| thr.join(SolidQueue.shutdown_timeout) }
      end

      def perform_graceful_termination
        # All done when stopping
      end

      def perform_immediate_termination
        exit!
      end

      def all_processes_terminated?
        threads.values.none?(&:alive?)
      end
  end
end
