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
    def run
      stop unless registered?
    end

    def clean_up
      deregister
    end

    def register
      @process = SolidQueue::Process.register(name)
    end

    def registered?
      SolidQueue::Process.registered?(name)
    end

    def deregister
      SolidQueue::Process.deregister(name)
      SolidQueue::ClaimedExecution.release_all_from(name)
    end

    def process
      @process ||= SolidQueue::Process.find_by(name: name)
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
end
