# frozen_string_literal: true

module SolidQueue::Processes
  module Supervised
    extend ActiveSupport::Concern

    included do
      attr_reader :supervisor
    end

    def supervised_by(process)
      @supervisor = process
    end

    private
      def set_procline
        procline "waiting"
      end

      def supervisor_went_away?
        supervised? && supervisor.pid != ::Process.ppid
      end

      def supervised?
        supervisor.present?
      end

      def create_fork(&block)
        fork do
          register_signal_handlers
          block.call

          # Exit skipping at-exit hooks and finalizers, like Puma's cluster
          # workers do: Ruby would finalize every object still alive in the
          # fork, including SQLite database handles whose mutex can be left
          # locked when a thread is killed while waiting in SQLite's busy
          # handler, deadlocking the exit. Everything the process needs to do
          # on shutdown has already run by now.
          exit!(0)
        end
      end

      def register_signal_handlers
        %w[ INT TERM ].each do |signal|
          trap(signal) do
            stop
          end
        end

        trap(:QUIT) do
          exit!
        end
      end
  end
end
