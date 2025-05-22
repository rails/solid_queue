# frozen_string_literal: true

module SolidQueue::Processes
  module Registrable
    extend ActiveSupport::Concern

    included do
      after_boot :register, :launch_heartbeat

      after_shutdown :stop_heartbeat, :deregister
    end

    def process_id
      process&.id
    end

    private
      attr_accessor :process

      def register
        @process = SolidQueue::Process.register \
          kind: kind,
          name: name,
          pid: pid,
          hostname: hostname,
          supervisor: try(:supervisor),
          metadata: metadata.compact
      end

      def deregister
        process&.deregister
      end

      def registered?
        process.present?
      end

      def launch_heartbeat
        @heartbeat_task = Concurrent::TimerTask.new(execution_interval: SolidQueue.process_heartbeat_interval) do
          wrap_in_app_executor { heartbeat }
        end

        @heartbeat_task.add_observer do |_, _, error|
          handle_thread_error(error) if error
        end

        @heartbeat_task.execute
      end

      def stop_heartbeat
        @heartbeat_task&.shutdown
      end

      def heartbeat
        process.heartbeat
      rescue ActiveRecord::RecordNotFound
        self.process = nil
        wake_up
      end
  end
end
