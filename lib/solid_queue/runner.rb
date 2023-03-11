# frozen_string_literal: true

module SolidQueue::Runner
  extend ActiveSupport::Concern

  included do
    include ActiveSupport::Callbacks
    define_callbacks :start, :stop, :run

    include SolidQueue::AppExecutor
    include ProcessRegistration

    attr_accessor :supervisor_pid
  end

  def start
    @stopping = false

    run_callbacks(:start) do
      start_loop
    end

    SolidQueue.logger.info("[SolidQueue] Started #{self}")
  end

  def stop
    @stopping = true

    run_callbacks(:stop) do
      wait
    end
  end

  def running?
    !stopping?
  end

  private
    def start_loop
      loop do
        break if stopping?
        run_callbacks :run do
          run
        end
      end
    ensure
      clean_up
    end

    def run
    end

    def stopping?
      @stopping
    end

    def clean_up
    end

    def interruptable_sleep(seconds)
      while !stopping? && seconds > 0
        Kernel.sleep 0.1
        seconds -= 0.1
      end
    end

    def hostname
      @hostname ||= Socket.gethostname
    end

    def pid
      @pid ||= Process.pid
    end
end
