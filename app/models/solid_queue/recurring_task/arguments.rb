module SolidQueue
  class RecurringTask::Arguments
    class << self
      def load(data)
        data.nil? ? [] : ActiveJob::Arguments.deserialize(ActiveSupport::JSON.load(data))
      end

      def dump(data)
        ActiveSupport::JSON.dump(ActiveJob::Arguments.serialize(data)) unless data.nil?
      end
    end
  end
end
