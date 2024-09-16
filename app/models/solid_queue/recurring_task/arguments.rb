# frozen_string_literal: true

require "active_job/arguments"

module SolidQueue
  class RecurringTask::Arguments
    class << self
      def load(data)
        data.nil? ? [] : ActiveJob::Arguments.deserialize(ActiveSupport::JSON.load(data))
      end

      def dump(data)
        ActiveSupport::JSON.dump(ActiveJob::Arguments.serialize(Array(data)))
      end
    end
  end
end
