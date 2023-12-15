# frozen_string_literal: true

module SolidQueue::Processes
  class GracefulTerminationRequested < Interrupt; end
  class ImmediateTerminationRequested < Interrupt; end

  module Signals
    extend ActiveSupport::Concern

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
          request_graceful_termination
        when :QUIT
          request_immediate_termination
        else
          SolidQueue.logger.warn "Received unhandled signal #{signal}"
        end
      end

      def request_graceful_termination
        raise GracefulTerminationRequested
      end

      def request_immediate_termination
        raise ImmediateTerminationRequested
      end

      def signal_processes(pids, signal)
        pids.each do |pid|
          signal_process pid, signal
        end
      end

      def signal_process(pid, signal)
        ::Process.kill signal, pid
      rescue Errno::ESRCH
        # Ignore, process died before
      end

      def signal_queue
        @signal_queue ||= []
      end
  end
end
