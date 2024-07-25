# frozen_string_literal: true

module SolidQueue
  class Process
    module Executor
      extend ActiveSupport::Concern

      included do
        has_many :claimed_executions

        after_destroy -> { claimed_executions.release_all }, if: :claims_executions?
      end

      private
        def claims_executions?
          kind == "Worker"
        end
    end
  end
end
