# frozen_string_literal: true

module SolidQueue::Runnable
  def start
    trap_signals
    @stopping = false
    @thread = Thread.new { run }
  end

  def stop
    @stopping = true
    wait
  end

  private
    def trap_signals
      %w[ INT TERM ].each do |signal|
        trap(signal) { stop }
      end
    end

    def run
    end

    def stopping?
      @stopping
    end

    def wait
      @thread&.join
    end
end
