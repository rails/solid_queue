# frozen_string_literal: true

module SolidQueue
  class Scheduler::RecurringSchedule
    include AppExecutor

    attr_reader :scheduled_tasks

    def initialize(static_tasks, dynamic_tasks_enabled: false)
      @static_tasks = Array(static_tasks).map { |task| RecurringTask.wrap(task) }.select(&:valid?)
      @dynamic_tasks_enabled = dynamic_tasks_enabled

      @scheduled_tasks = Concurrent::Hash.new
    end

    def configured_tasks
      static_tasks + dynamic_tasks
    end

    def empty?
      scheduled_tasks.empty? && dynamic_tasks.empty?
    end

    def schedule_tasks
      wrap_in_app_executor do
        persist_static_tasks
        reload_static_tasks
        reload_dynamic_tasks
      end

      configured_tasks.each do |task|
        schedule_task(task)
      end
    end

    def schedule_task(task)
      scheduled_tasks[task.key] = schedule(task)
    end

    def unschedule_tasks
      scheduled_tasks.values.each(&:cancel)
      scheduled_tasks.clear
    end

    def task_keys
      configured_tasks.map(&:key)
    end

    def reschedule_dynamic_tasks
      wrap_in_app_executor do
        reload_dynamic_tasks
        schedule_created_dynamic_tasks
        unschedule_deleted_dynamic_tasks
      end
    end

    private
      attr_reader :static_tasks

      def static_task_keys
        static_tasks.map(&:key)
      end

      def dynamic_tasks
        @dynamic_tasks ||= load_dynamic_tasks
      end

      def dynamic_tasks_enabled?
        @dynamic_tasks_enabled
      end

      def schedule_created_dynamic_tasks
        RecurringTask.dynamic.where.not(key: scheduled_tasks.keys).each do |task|
          schedule_task(task)
        end
      end

      def unschedule_deleted_dynamic_tasks
        (scheduled_tasks.keys - RecurringTask.pluck(:key)).each do |key|
          scheduled_tasks[key].cancel
          scheduled_tasks.delete(key)
        end
      end

      def persist_static_tasks
        RecurringTask.static.where.not(key: static_task_keys).delete_all
        RecurringTask.create_or_update_all static_tasks
      end

      def reload_static_tasks
        @static_tasks = RecurringTask.static.where(key: static_task_keys).to_a
      end

      def reload_dynamic_tasks
        @dynamic_tasks = load_dynamic_tasks
      end

      def load_dynamic_tasks
        dynamic_tasks_enabled? ? RecurringTask.dynamic.to_a : []
      end

      def schedule(task)
        scheduled_task = Concurrent::ScheduledTask.new(task.delay_from_now, args: [ self, task, task.next_time ]) do |thread_schedule, thread_task, thread_task_run_at|
          thread_schedule.schedule_task(thread_task)

          wrap_in_app_executor do
            thread_task.enqueue(at: thread_task_run_at)
          end
        end

        scheduled_task.add_observer do |_, _, error|
          # Don't notify on task cancellation before execution, as this will happen normally
          # as part of unloading tasks
          handle_thread_error(error) if error && !error.is_a?(Concurrent::CancelledOperationError)
        end

        scheduled_task.tap(&:execute)
      end
  end
end
