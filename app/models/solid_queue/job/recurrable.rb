# frozen_string_literal: true

module SolidQueue
  class Job
    module Recurrable
      extend ActiveSupport::Concern

      included do
        has_one :recurring_execution, dependent: :destroy
      end
    end
  end
end
