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

    def schedule_task(task, run_at: task.next_time)
      scheduled_tasks[task.key] = schedule(task, run_at: run_at)
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
        @configured_tasks = SolidQueue::RecurringTask.where(key: task_keys).to_a
      end

      def schedule(task, run_at: task.next_time)
        delay = [ (run_at - Time.current).to_f, 0.1 ].max

        scheduled_task = Concurrent::ScheduledTask.new(delay, args: [ self, task, run_at ]) do |thread_schedule, thread_task, thread_task_run_at|
          thread_schedule.schedule_task(thread_task, run_at: thread_task.next_time_after(thread_task_run_at))

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
