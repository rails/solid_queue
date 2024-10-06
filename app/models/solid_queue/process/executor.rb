# frozen_string_literal: true

module SolidQueue
  class Process
    module Executor
      extend ActiveSupport::Concern

      included do
        has_many :claimed_executions

        after_destroy :release_all_claimed_executions
      end

      def fail_all_claimed_executions_with(error, reraise:)
        if claims_executions?
          claimed_executions.fail_all_with(error, reraise: reraise)
        end
      end

      def release_all_claimed_executions
        if claims_executions?
          claimed_executions.release_all
        end
      end

      private
        def claims_executions?
          kind == "Worker"
        end
    end
  end
end
