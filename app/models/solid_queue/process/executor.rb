# frozen_string_literal: true

module SolidQueue
  class Process
    module Executor
      extend ActiveSupport::Concern

      included do
        if ClaimedExecution.process_name_column_exists?
          has_many :claimed_executions, primary_key: :name, foreign_key: :process_name
        else
          warn_about_pending_migrations

          has_many :claimed_executions
        end

        after_destroy :release_all_claimed_executions
      end

      def fail_all_claimed_executions_with(error)
        if claims_executions?
          claimed_executions.fail_all_with(error)
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
