# frozen_string_literal: true

module SolidQueue
  class Process
    module Executor
      extend ActiveSupport::Concern

      included do
        has_many :claimed_executions

        after_destroy -> { claimed_executions.release_all }, if: :claims_executions?
      end

      def fail_all_claimed_executions_with(error)
        if claims_executions?
          claimed_executions.fail_all_with(error)
        end
      end

      private
        def claims_executions?
          kind == "Worker"
        end
    end
  end
end
