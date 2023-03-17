# frozen_string_literal: true

module SolidQueue::Runner
  extend ActiveSupport::Concern

  included do
    include ActiveSupport::Callbacks
    define_callbacks :start, :run, :shutdown

    include SolidQueue::AppExecutor
    include ProcessRegistration

    attr_accessor :supervisor_pid
  end

  def start(mode: :sync)
    @stopping = false
    trap_signals

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
    def trap_signals
      %w[ INT TERM ].each do |signal|
        trap(signal) { stop }
      end
    end

    def start_loop
      loop do
        break if shutdown?
        run_callbacks(:run) { run }
      end
    ensure
      run_callbacks(:shutdown) { shutdown }
    end

    def run
    end

    def shutdown
    end

    def shutdown?
      stopping? || supervisor_went_away?
    end

    def stopping?
      @stopping
    end

    def supervisor_went_away?
      if running_in_async_mode?
        false
      else
        supervisor_pid != Process.ppid
      end
    end

    def running_in_async_mode?
      @thread.present?
    end

    def interruptable_sleep(seconds)
      while !stopping? && seconds > 0
        sleep 0.1
        seconds -= 0.1
      end
    end

    def hostname
      @hostname ||= Socket.gethostname
    end

    def process_pid
      @pid ||= Process.pid
    end
end
