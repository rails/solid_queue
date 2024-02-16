# frozen_string_literal: true

module SolidQueue
  class Dispatcher::RecurringTasks
    include AppExecutor

    attr_reader :interval, :batch_size

    def initialize(configured_tasks)
      @configured_tasks = configured_tasks
    end

    def schedule
    end

    def unschedule
    end
  end
end
