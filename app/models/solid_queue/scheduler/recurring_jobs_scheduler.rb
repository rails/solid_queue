# frozen_string_literal: true

module SolidQueue
  class Scheduler::RecurringJobsScheduler < Scheduler
    attr_accessor :polling_interval, :entries, :tasks

    def initialize(**options)
      options = options.dup.with_defaults(SolidQueue::Configuration::SCHEDULER_DEFAULTS)

      @polling_interval = options[:polling_interval]
      @entries = SolidQueue::RecurringJobs::Entry.initialize_all(options[:recurring_jobs])
      @tasks = Concurrent::Hash.new
    end

      def manage_task_for(entry)
        if tasks[entry.id].nil? || !tasks[entry.id].pending?
          task = schedule_task_for(entry)
          tasks[entry.id] = task
        end
      end

    private
      def run
        manage_schedule

        procline "waiting"
        interruptible_sleep(polling_interval)
      end

      def manage_schedule
        entries.each do |entry|
          manage_task_for(entry)
        end
      end

      def schedule_task_for(entry)
        task = Concurrent::ScheduledTask.new(entry.delay_from_now, args: [ self, entry ]) do |thread_scheduler, thread_entry|
          thread_scheduler.manage_task_for(thread_entry)

          wrap_in_app_executor do
            thread_entry.enqueue
          end
        end

        task.add_observer do |_, _, error|
          handle_thread_error(error) if error
        end

        task.tap(&:execute)
      end

      def shutdown
        super

        tasks.values.each(&:cancel)
        tasks.clear
      end

      def metadata
        super.merge(entries: entries.map(&:to_s))
      end
  end
end
