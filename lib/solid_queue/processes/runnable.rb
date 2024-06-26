# frozen_string_literal: true

module SolidQueue::Processes
  module Runnable
    include Supervised

    attr_writer :mode

    def start
      @stopping = false

      SolidQueue.instrument(:start_process, process: self) do
        run_callbacks(:boot) { boot }
      end

      if mode.async?
        @thread = Thread.new { run }
      else
        run
      end
    end

    def stop
      @stopping = true
      @thread&.join
    end

    private
      DEFAULT_MODE = :async

      def mode
        (@mode || DEFAULT_MODE).to_s.inquiry
      end

      def boot
        if supervised?
          register_signal_handlers
          set_procline
        end
      end

      def shutting_down?
        stopping? || supervisor_went_away? || finished?
      end

      def run
        raise NotImplementedError
      end

      def stopping?
        @stopping
      end

      def finished?
        running_inline? && all_work_completed?
      end

      def all_work_completed?
        false
      end

      def set_procline
      end

      def running_inline?
        mode.inline?
      end
  end
end
