# frozen_string_literal: true

class SolidQueue::Supervisor
  attr_accessor :dispatchers, :scheduler

  def self.start
    configuration = SolidQueue::Configuration.new
    dispatchers = configuration.queues.values.map { |queue_options| SolidQueue::Dispatcher.new(**queue_options) }
    scheduler = unless configuration.scheduler_disabled?
      SolidQueue::Scheduler.new(**configuration.scheduler_options)
    end

    new(dispatchers, scheduler).start
  end

  def initialize(dispatchers, scheduler = nil)
    @dispatchers = dispatchers
    @scheduler = scheduler
  end

  def start
    trap_signals
    dispatchers.each(&:start)
    scheduler&.start

    Kernel.loop do
      sleep 0.1
      break if stopping?
    end

    dispatchers.each(&:stop)
    scheduler&.stop
  end

  private
    def trap_signals
      %w[ INT TERM ].each do |signal|
        trap(signal) { stop }
      end
    end

    def stop
      @stopping = true
    end

    def stopping?
      @stopping
    end
end
