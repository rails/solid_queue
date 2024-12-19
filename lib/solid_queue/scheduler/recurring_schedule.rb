# frozen_string_literal: true

module SolidQueue
  class Scheduler::RecurringSchedule
    include AppExecutor

    attr_reader :configured_tasks, :scheduled_tasks

    def initialize(tasks)
      @configured_tasks = Array(tasks).map { |task| SolidQueue::RecurringTask.wrap(task) }.select(&:valid?)
      @scheduled_tasks = Concurrent::Hash.new
    end

    def empty?
      configured_tasks.empty?
    end

    def schedule_tasks
      wrap_in_app_executor do
        persist_tasks
        reload_tasks
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

    private
      def persist_tasks
        SolidQueue::RecurringTask.static.where.not(key: task_keys).delete_all
        SolidQueue::RecurringTask.create_or_update_all configured_tasks
      end

      def reload_tasks
        @configured_tasks = SolidQueue::RecurringTask.where(key: task_keys)
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
