# frozen_string_literal: true

module SolidQueue::Processes
  module Registrable
    extend ActiveSupport::Concern

    included do
      set_callback :boot, :after, :register
      set_callback :boot, :after, :launch_heartbeat

      set_callback :shutdown, :before, :stop_heartbeat
      set_callback :shutdown, :after, :deregister
    end

    def inspect
      "#{kind}(pid=#{process_pid}, hostname=#{hostname}, metadata=#{metadata})"
    end
    alias to_s inspect

    private
      attr_accessor :process

      def register
        @process = SolidQueue::Process.register \
          kind: self.class.name.demodulize,
          pid: process_pid,
          hostname: hostname,
          supervisor: try(:supervisor),
          metadata: metadata
      end

      def deregister
        process.deregister if registered?
      end

      def registered?
        process&.persisted?
      end

      def launch_heartbeat
        @heartbeat_task = Concurrent::TimerTask.new(execution_interval: SolidQueue.process_heartbeat_interval) { heartbeat }
        @heartbeat_task.execute
      end

      def stop_heartbeat
        @heartbeat_task&.shutdown
      end

      def heartbeat
        process.heartbeat
      end

      def kind
        self.class.name.demodulize
      end

      def hostname
        @hostname ||= Socket.gethostname
      end

      def process_pid
        @pid ||= ::Process.pid
      end

      def metadata
        {}
      end
  end
end
