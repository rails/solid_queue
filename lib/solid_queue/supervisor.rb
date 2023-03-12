# frozen_string_literal: true

class SolidQueue::Supervisor
  class << self
    def start(mode: :all, configuration: SolidQueue::Configuration.new)
      runners = case mode
      when :schedule then scheduler(configuration)
      when :work     then dispatchers(configuration)
      when :all      then [ scheduler(configuration) ] + dispatchers(configuration)
      else           raise "Invalid mode #{mode}"
      end

      new(runners).start
    end

    def dispatchers(configuration)
      configuration.queues.values.map { |queue_options| SolidQueue::Dispatcher.new(**queue_options) }
    end

    def scheduler(configuration)
      SolidQueue::Scheduler.new(**configuration.scheduler_options)
    end
  end

  attr_accessor :runners

  def initialize(runners)
    @runners = Array(runners)
  end

  def start
    trap_signals
    prune_dead_processes
    runners.each(&:start)

    Kernel.loop do
      sleep 0.1
      break if stopping?
    end

    runners.each(&:stop)
  end

  def stop
    @stopping = true
  end

  private
    def trap_signals
      %w[ INT TERM ].each do |signal|
        trap(signal) { stop }
      end
    end

    def prune_dead_processes
      SolidQueue::Process.prune
    end

    def stopping?
      @stopping
    end
end
