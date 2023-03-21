# frozen_string_literal: true

module SolidQueue
  class GracefulShutdownRequested < Interrupt; end
  class ImmediateShutdownRequested < Interrupt; end

  module Signals
    extend ActiveSupport::Concern

    included do
      include Interruptible
    end

    private
      SIGNALS = %i[ QUIT INT TERM ]

      def register_signal_handlers
        SIGNALS.each do |signal|
          trap(signal) do
            signal_queue << signal
            interrupt
          end
        end
      end

      def restore_default_signal_handlers
        SIGNALS.each do |signal|
          trap(signal, :DEFAULT)
        end
      end

      def process_signal_queue
        while signal = signal_queue.shift
          handle_signal(signal)
        end
      end

      def handle_signal(signal)
        case signal
        when :TERM, :INT
          request_graceful_shutdown
        when :QUIT
          request_immediate_shutdown
        else
          SolidQueue.logger.warn "Received unhandled signal #{signal}"
        end
      end

      def request_graceful_shutdown
        raise GracefulShutdownRequested
      end

      def request_immediate_shutdown
        raise ImmediateShutdownRequested
      end

      def signal_processes(pids, signal)
        pids.each do |pid|
          ::Process.kill signal, pid
        end
      end

      def signal_queue
        @signal_queue ||= []
      end
  end
end
