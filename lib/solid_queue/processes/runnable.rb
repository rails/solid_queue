# frozen_string_literal: true

module SolidQueue::Processes
  module Runnable
    include Supervised

    def start
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
    attr_writer :mode

    DEFAULT_MODE = :async

    def mode
      (@mode || DEFAULT_MODE).to_s.inquiry
    end

    def boot
      register_signal_handlers if supervised?
      SolidQueue.logger.info("[SolidQueue] Starting #{self}")
    end

    def start_loop
      if mode.async?
        @thread = Thread.new { do_start_loop }
      else
        do_start_loop
      end
    end

    def do_start_loop
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

    def stopping?
      @stopping
    end

    def finished?
      running_inline? && all_work_completed?
    end

    def all_work_completed?
      false
    end

    def running_inline?
      mode.inline?
    end
  end
end
