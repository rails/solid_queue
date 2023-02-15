# frozen_string_literal: true

class SolidQueue::Manager
  include SolidQueue::Runnable

  attr_accessor :dispatchers, :scheduler

  def self.start
    configuration = SolidQueue::Configuration.new
    dispatchers = configuration.queues.map { |queue| SolidQueue::Dispatcher.new(queue) }
    scheduler = unless configuration.scheduler_disabled?
      SolidQueue::Scheduler.new(configuration.scheduler_options)
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
end
