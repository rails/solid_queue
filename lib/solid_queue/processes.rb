# frozen_string_literal: true

module SolidQueue::Processes
  def start
    register
    start_heartbeat
    prune_dead_processes
    super
  end

  def stop
    stop_heartbeat
    super
  end

  private
    attr_accessor :process

    def run
      stop unless registered?
    end

    def clean_up
      process.deregister
    end

    def register
      @process = SolidQueue::Process.register(metadata)
    end

    def registered?
      process.persisted?
    end

    def start_heartbeat
      @heartbeat_task = Concurrent::TimerTask.new(execution_interval: SolidQueue::Process::HEARTBEAT_INTERVAL) { heartbeat }
      @heartbeat_task.execute
    end

    def heartbeat
      process.heartbeat
    end

    def stop_heartbeat
      @heartbeat_task.shutdown
    end

    def prune_dead_processes
      SolidQueue::Process.prune
    end

    def metadata
      { hostname: hostname, pid: pid, queue: queue }
    end
end
