# frozen_string_literal: true

module SolidQueue::Runner::ProcessRegistration
  extend ActiveSupport::Concern

  included do
    include ActiveSupport::Callbacks
    define_callbacks :start, :run, :shutdown

    set_callback :start, :before, :register
    set_callback :start, :before, :start_heartbeat

    set_callback :run, :after, -> { stop unless registered? }

    set_callback :shutdown, :before, :stop_heartbeat
    set_callback :shutdown, :after, :deregister

    attr_accessor :supervisor_pid
  end

  def inspect
    metadata.inspect
  end
  alias to_s inspect

  private
    attr_accessor :process

    def register
      @process = SolidQueue::Process.register(metadata)
    end

    def deregister
      process.deregister
    end

    def registered?
      process.persisted?
    end

    def start_heartbeat
      @heartbeat_task = Concurrent::TimerTask.new(execution_interval: SolidQueue.process_heartbeat_interval) { heartbeat }
      @heartbeat_task.execute
    end

    def stop_heartbeat
      @heartbeat_task.shutdown
    end

    def heartbeat
      process.heartbeat
    end

    def hostname
      @hostname ||= Socket.gethostname
    end

    def process_pid
      @pid ||= ::Process.pid
    end

    def metadata
      { kind: self.class.name.demodulize, hostname: hostname, pid: process_pid, supervisor_pid: supervisor_pid }
    end
end
