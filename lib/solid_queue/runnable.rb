# frozen_string_literal: true

module SolidQueue::Runnable
  def start
    @stopping = false
    @thread = Thread.new { start_loop }

    log "Started #{self}"
  end

  def stop
    @stopping = true
    wait
  end

  def running?
    !stopping?
  end

  private
    def start_loop
      loop do
        break if stopping?
        run
      end
    ensure
      clean_up
    end

    def run
    end

    def stopping?
      @stopping
    end

    def wait
      @thread&.join
    end

    def clean_up
    end

    def wrap_in_app_executor(&block)
      if SolidQueue.app_executor
        SolidQueue.app_executor.wrap(&block)
      else
        yield
      end
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

    def log(message)
      SolidQueue.logger.info("[SolidQueue] #{message}")
    end
end
