# frozen_string_literal: true

module SolidQueue
  class Scheduler::RecurringSchedule
    include AppExecutor

    attr_reader :scheduled_tasks

    def initialize(static_tasks, dynamic_tasks_enabled: false)
      @static_tasks = Array(static_tasks).map { |task| RecurringTask.wrap(task) }.select(&:valid?)
      @dynamic_tasks_enabled = dynamic_tasks_enabled

      @schedule_lock = Mutex.new
      @scheduled_tasks = Concurrent::Hash.new
      @scheduled_dynamic_task_ids = {}
      @active = false
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

      schedule_lock.synchronize do
        @active = true
        configured_tasks.each { |task| schedule_task_without_lock(task) }
      end
    end

    def schedule_task(task, run_at: task.next_time)
      schedule_lock.synchronize { schedule_task_without_lock(task, run_at: run_at) }
    end

    def unschedule_tasks
      schedule_lock.synchronize do
        @active = false
        scheduled_tasks.values.each(&:cancel)
        scheduled_tasks.clear
        scheduled_dynamic_task_ids.clear
      end
    end

    def task_keys
      configured_tasks.map(&:key)
    end

    def reschedule_dynamic_tasks
      wrap_in_app_executor do
        schedule_lock.synchronize do
          reload_dynamic_tasks
          schedule_created_dynamic_tasks
          reschedule_recreated_dynamic_tasks
          unschedule_deleted_dynamic_tasks
        end
      end
    end

    private
      attr_reader :static_tasks, :schedule_lock, :scheduled_dynamic_task_ids

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
        dynamic_tasks.reject { |task| scheduled_tasks.key?(task.key) }.each do |task|
          schedule_task_without_lock(task)
        end
      end

      def reschedule_recreated_dynamic_tasks
        dynamic_tasks.each do |task|
          next unless scheduled_dynamic_task_ids.key?(task.key)
          next if scheduled_dynamic_task_ids[task.key] == task.id

          unschedule_task(task.key)
          schedule_task_without_lock(task)
        end
      end

      def unschedule_deleted_dynamic_tasks
        (scheduled_dynamic_task_ids.keys - dynamic_tasks.map(&:key)).each { |key| unschedule_task(key) }
      end

      def unschedule_task(key)
        scheduled_tasks.delete(key)&.cancel
        scheduled_dynamic_task_ids.delete(key)
      end

      def schedule_task_without_lock(task, run_at: task.next_time)
        scheduled_tasks[task.key] = schedule(task, run_at: run_at)
        scheduled_dynamic_task_ids[task.key] = task.id unless task.static?
      end

      def schedule_next_task(task, run_at:)
        schedule_lock.synchronize do
          schedule_task_without_lock(task, run_at: run_at) if @active && current_task?(task)
        end
      end

      def current_task?(task)
        task.static? || scheduled_dynamic_task_ids[task.key] == task.id
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

      def schedule(task, run_at: task.next_time)
        delay = [ (run_at - Time.current).to_f, 0.1 ].max

        scheduled_task = Concurrent::ScheduledTask.new(delay, args: [ task, run_at ]) do |thread_task, thread_task_run_at|
          schedule_next_task(thread_task, run_at: thread_task.next_time_after(thread_task_run_at))

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
