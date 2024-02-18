# frozen_string_literal: true

module SolidQueue
  class Job
    module Recurrable
      extend ActiveSupport::Concern

      included do
        has_one :recurring_execution
      end

      private
        def execution
          super || recurring_execution
        end
    end
  end
end
