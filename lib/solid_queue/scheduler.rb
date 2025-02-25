# frozen_string_literal: true

module SolidQueue
  class Scheduler < Processes::Base
    include Processes::Runnable
    include LifecycleHooks

    attr_reader :recurring_schedule

    after_boot :run_start_hooks
    after_boot :schedule_recurring_tasks
    before_shutdown :unschedule_recurring_tasks
    before_shutdown :run_stop_hooks
    after_shutdown :run_exit_hooks

    def initialize(recurring_tasks:, **options)
      @recurring_schedule = RecurringSchedule.new(recurring_tasks)

      super(**options)
    end

    def metadata
      super.merge(recurring_schedule: recurring_schedule.task_keys.presence)
    end

    private
      SLEEP_INTERVAL = 60 # Right now it doesn't matter, can be set to 1 in the future for dynamic tasks

      def run
        loop do
          break if shutting_down?

          interruptible_sleep(SLEEP_INTERVAL)
        end
      ensure
        SolidQueue.instrument(:shutdown_process, process: self) do
          run_callbacks(:shutdown) { shutdown }
        end
      end

      def schedule_recurring_tasks
        recurring_schedule.schedule_tasks
      end

      def unschedule_recurring_tasks
        recurring_schedule.unschedule_tasks
      end

      def all_work_completed?
        recurring_schedule.empty?
      end

      def set_procline
        procline "scheduling #{recurring_schedule.task_keys.join(",")}"
      end
  end
end
