# frozen_string_literal: true

module SolidQueue::Processes
  module Runnable
    include Supervised

    attr_writer :mode

    def start
      @stopping = false
      run_callbacks(:boot) { boot }

      run
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

        SolidQueue.logger.info("[SolidQueue] Starting #{self}")
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
