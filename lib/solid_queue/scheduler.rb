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
      options = options.dup.with_defaults(SolidQueue::Configuration::SCHEDULER_DEFAULTS)
      @dynamic_tasks_enabled = options[:dynamic_tasks_enabled]
      @polling_interval = options[:polling_interval]
      @recurring_schedule = RecurringSchedule.new(recurring_tasks, dynamic_tasks_enabled: @dynamic_tasks_enabled)

      super(**options)
    end

    def metadata
      super.merge(recurring_schedule: recurring_schedule.task_keys.presence)
    end

    private

      STATIC_SLEEP_INTERVAL = 60

      def run
        loop do
          break if shutting_down?

          reload_dynamic_schedule if dynamic_tasks_enabled?

          interruptible_sleep(sleep_interval)
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

      def reload_dynamic_schedule
        recurring_schedule.reschedule_dynamic_tasks
        reload_metadata
      end

      def dynamic_tasks_enabled?
        @dynamic_tasks_enabled
      end

      def all_work_completed?
        recurring_schedule.empty?
      end

      def sleep_interval
        dynamic_tasks_enabled? ? polling_interval : STATIC_SLEEP_INTERVAL
      end

      def set_procline
        procline "scheduling #{recurring_schedule.task_keys.join(",")}"
      end
  end
end
