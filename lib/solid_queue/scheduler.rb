# frozen_string_literal: true

module SolidQueue
  class Scheduler < Processes::Base
    include Processes::Runnable
    include LifecycleHooks

    attr_reader :recurring_schedule, :polling_interval

    after_boot :run_start_hooks
    after_boot :schedule_recurring_tasks
    before_shutdown :unschedule_recurring_tasks
    before_shutdown :run_stop_hooks
    after_shutdown :run_exit_hooks

    def initialize(recurring_tasks:, **options)
      @recurring_schedule = RecurringSchedule.new(recurring_tasks)
      options = options.dup.with_defaults(SolidQueue::Configuration::SCHEDULER_DEFAULTS)
      @polling_interval = options[:polling_interval]

      super(**options)
    end

    def metadata
      super.merge(recurring_schedule: recurring_schedule.task_keys.presence)
    end

    private
      def run
        loop do
          break if shutting_down?

          recurring_schedule.reload!
          refresh_registered_process if recurring_schedule.changed?

          interruptible_sleep(polling_interval)
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
