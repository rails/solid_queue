# frozen_string_literal: true

module SolidQueue
  class Scheduler::RecurringSchedule
    include AppExecutor

    attr_reader :scheduled_tasks

    def initialize(tasks)
      @static_tasks = Array(tasks).map { |task| SolidQueue::RecurringTask.wrap(task) }.select(&:valid?)
      @scheduled_tasks = Concurrent::Hash.new
      @changes = Concurrent::Hash.new
    end

    def configured_tasks
      static_tasks + dynamic_tasks.to_a
    end

    def empty?
      scheduled_tasks.empty? && dynamic_tasks.none?
    end

    def schedule_tasks
      wrap_in_app_executor do
        persist_static_tasks
        reload_static_tasks
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
      static_task_keys + dynamic_tasks.pluck(:key)
    end

    def reload!
      wrap_in_app_executor do
        { added_tasks: schedule_new_dynamic_tasks,
          removed_tasks: unschedule_old_dynamic_tasks }.each do |key, values|
          if values.any?
            @changes[key] = values
          else
            @changes.delete(key)
          end
        end
      end
    end

    def changed?
      @changes.any?
    end

    def clear_changes
      @changes.clear
    end

    private
      attr_reader :static_tasks

      def dynamic_tasks
        SolidQueue::RecurringTask.dynamic
      end

      def static_task_keys
        static_tasks.map(&:key)
      end

      def schedule_new_dynamic_tasks
        dynamic_tasks.where.not(key: scheduled_tasks.keys).each do |task|
          schedule_task(task)
        end
      end

      def unschedule_old_dynamic_tasks
        (scheduled_tasks.keys - SolidQueue::RecurringTask.pluck(:key)).each do |key|
          scheduled_tasks[key].cancel
          scheduled_tasks.delete(key)
        end
      end

      def persist_static_tasks
        SolidQueue::RecurringTask.static.where.not(key: static_task_keys).delete_all
        SolidQueue::RecurringTask.create_or_update_all static_tasks
      end

      def reload_static_tasks
        @static_tasks = SolidQueue::RecurringTask.static.where(key: static_task_keys).to_a
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
