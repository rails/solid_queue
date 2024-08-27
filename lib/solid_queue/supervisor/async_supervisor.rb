# frozen_string_literal: true

module SolidQueue
  class Supervisor::AsyncSupervisor < Supervisor
    skip_callback :boot, :before, :register_signal_handlers, if: :sidecar?

    def initialize(*, sidecar: false)
      super

      @sidecar = sidecar
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

      def sidecar?
        @sidecar
      end

      def start_process(configured_process)
        process_instance = configured_process.instantiate.tap do |instance|
          instance.supervised_by process
        end

        process_instance.start

        threads[process_instance.name] = process_instance
      end

      def supervise
        unless sidecar?
          loop do
            break if stopped?

            procline "supervising #{threads.keys.join(", ")}"
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

      def terminate_gracefully
        instrument_termination(:graceful) do |payload|
          payload[:supervised_processes] = threads.keys

          unless all_threads_terminated?
            payload[:shutdown_timeout_exceeded] = true
            terminate_immediately
          end
        end
      end

      def terminate_immediately
        instrument_termination(:immediate) do |payload|
          payload[:supervised_processes] = threads.keys

          exit!
        end
      end

      def all_threads_terminated?
        threads.values.none?(&:alive?)
      end
  end
end
