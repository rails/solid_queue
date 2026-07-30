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
        wrap_in_app_executor do
          @process = SolidQueue::Process.register \
            kind: kind,
            name: name,
            pid: pid,
            hostname: hostname,
            supervisor: try(:supervisor),
            metadata: metadata.compact
        end
      end

      def deregister
        wrap_in_app_executor { process&.deregister }
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
        process&.heartbeat
        @heartbeats_failing_since = nil
      rescue ActiveRecord::RecordNotFound
        self.process = nil
        wake_up
      rescue => error
        # Errors other than a missing registration (e.g. the DB connection dropping)
        # can prevent the heartbeat from going through, and even from finding out
        # whether the registration is still there. If this persists past the alive
        # threshold, other processes will have considered this one dead and pruned
        # its registration, so stop and let the supervisor replace it with a process
        # that can register afresh, rather than running unregistered indefinitely.
        @heartbeats_failing_since ||= Time.current
        if heartbeats_failing_for_too_long?
          self.process = nil
          wake_up
        end

        raise error
      end

      def heartbeats_failing_for_too_long?
        @heartbeats_failing_since && Time.current - @heartbeats_failing_since > SolidQueue.process_alive_threshold
      end

      def reload_metadata
        wrap_in_app_executor { process&.update(metadata: metadata.compact) }
      end
  end
end
