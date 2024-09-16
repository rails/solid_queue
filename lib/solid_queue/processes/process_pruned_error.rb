# frozen_string_literal: true

module SolidQueue
  module Processes
    class ProcessPrunedError < RuntimeError
      def initialize(last_heartbeat_at)
        super("Process was found dead and pruned (last heartbeat at: #{last_heartbeat_at}")
      end
    end
  end
end
