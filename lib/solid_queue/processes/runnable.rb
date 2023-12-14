# frozen_string_literal: true

module SolidQueue
  module Processes
    module Runnable
      def start(mode: :supervised)
        @mode = mode.to_s.inquiry
        @stopping = false

        observe_initial_delay
        run_callbacks(:boot) { boot }

        start_loop
      end

      def stop
        @stopping = true
        @thread&.join
      end

    private
      attr_reader :mode

      def boot
        register_signal_handlers
        SolidQueue.logger.info("[SolidQueue] Starting #{self}")
      end

      def register_signal_handlers
        %w[ INT TERM ].each do |signal|
          trap(signal) do
            stop
            interrupt
          end
        end

        trap(:QUIT) do
          exit!
        end
      end

      def start_loop
        if mode.async?
          @thread = Thread.new { do_start_loop }
        else
          do_start_loop
        end
      end

      def do_start_loop
        procline "started"

        loop do
          break if shutting_down?

          run
        end
      ensure
        run_callbacks(:shutdown) { shutdown }
      end

      def shutting_down?
        stopping? || supervisor_went_away? || finished?
      end

      def run
        raise NotImplementedError
      end

      def shutdown
        procline "shutting down"

      end

      def stopping?
        @stopping
      end

      def finished?
        running_inline? && all_work_completed?
      end

      def supervisor_went_away?
        supervised? && supervisor&.pid != ::Process.ppid
      end

      def supervised?
        mode.supervised?
      end

      def all_work_completed?
        false
      end

      def running_inline?
        mode.inline?
      end

      def with_polling_volume
        if SolidQueue.silence_polling?
          ActiveRecord::Base.logger.silence { yield }
        else
          yield
        end
      end
    end
  end
end
