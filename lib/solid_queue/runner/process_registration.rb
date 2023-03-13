# frozen_string_literal: true

module SolidQueue::Runner::ProcessRegistration
  extend ActiveSupport::Concern

  included do
    set_callback :start, :before, :register
    set_callback :start, :before, :start_heartbeat

    set_callback :run, :after, -> { stop unless registered? }

    set_callback :stop, :before, :stop_heartbeat
  end

  private
    attr_accessor :process

    def clean_up
      deregister
    end

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

    def metadata
      { kind: self.class.name.demodulize, hostname: hostname, pid: pid }
    end
end
