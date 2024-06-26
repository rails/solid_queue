# frozen_string_literal: true

module SolidQueue::Processes
  module Registrable
    extend ActiveSupport::Concern

    included do
      after_boot :register, :launch_heartbeat

      before_shutdown :stop_heartbeat
      after_shutdown :deregister
    end

    private
      attr_accessor :process

      def register
        @process = SolidQueue::Process.register \
          kind: kind,
          pid: pid,
          hostname: hostname,
          supervisor: try(:supervisor),
          metadata: metadata.compact
      end

      def deregister
        process.deregister if registered?
      end

      def registered?
        process&.persisted?
      end

      def launch_heartbeat
        @heartbeat_task = Concurrent::TimerTask.new(execution_interval: SolidQueue.process_heartbeat_interval) do
          wrap_in_app_executor { heartbeat }
        end

        @heartbeat_task.execute
      end

      def stop_heartbeat
        @heartbeat_task&.shutdown
      end

      def heartbeat
        process.heartbeat
      end
  end
end
