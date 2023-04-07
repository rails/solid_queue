# frozen_string_literal: true

module SolidQueue
  module Runner
    extend ActiveSupport::Concern

    included do
      include ActiveSupport::Callbacks
      define_callbacks :start, :run, :shutdown

      include AppExecutor, Procline
      include ProcessRegistration, Interruptible

      attr_accessor :supervisor_pid
    end

    def start(mode: :sync)
      procline "starting in mode #{mode}"

      @stopping = false
      register_signal_handlers

      SolidQueue.logger.info("[SolidQueue] Starting #{self}")

      run_callbacks(:start) do
        if mode == :async
          @thread = Thread.new { start_loop }
        else
          start_loop
        end
      end
    end

    def stop
      @stopping = true
      @thread.join if running_in_async_mode?
    end

    def running?
      !stopping?
    end

    private
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
        procline "started"

        loop do
          break if shutting_down?

          run_callbacks(:run) { run }
        end
      ensure
        run_callbacks(:shutdown) { shutdown }
      end

      def shutting_down?
        stopping? || supervisor_went_away?
      end

      def run
      end

      def shutdown
        procline "shutting down"
      end

      def stopping?
        @stopping
      end

      def shutdown_completed?
      end

      def supervisor_went_away?
        if running_in_async_mode?
          false
        else
          supervisor_pid != ::Process.ppid
        end
      end

      def running_in_async_mode?
        @thread.present?
      end

      def hostname
        @hostname ||= Socket.gethostname
      end

      def process_pid
        @pid ||= ::Process.pid
      end
  end
end
