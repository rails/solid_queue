require "fugit"

module SolidQueue
  class Dispatcher::RecurringTask
    class << self
      def wrap(args)
        args.is_a?(self) ? args : from_configuration(args.first, **args.second)
      end

      def from_configuration(key, **options)
        new(key, class_name: options[:class], schedule: options[:schedule], arguments: options[:args])
      end
    end

    attr_reader :key, :schedule, :class_name, :arguments

    def initialize(key, class_name:, schedule:, arguments: nil)
      @key = key
      @class_name = class_name
      @schedule = schedule
      @arguments = Array(arguments)
    end

    def delay_from_now
      [ (next_time - Time.current).to_f, 0 ].max
    end

    def next_time
      parsed_schedule.next_time.utc
    end

    def enqueue(at:)
      SolidQueue.instrument(:enqueue_recurring_task, task: key, at: at) do |payload|
        active_job = if using_solid_queue_adapter?
          perform_later_and_record(run_at: at)
        else
          payload[:other_adapter] = true

          perform_later
        end

        payload[:active_job_id] = active_job.job_id if active_job
      rescue RecurringExecution::AlreadyRecorded
        payload[:skipped] = true
      end
    end

    def valid?
      parsed_schedule.instance_of?(Fugit::Cron)
    end

    def to_s
      "#{class_name}.perform_later(#{arguments.map(&:inspect).join(",")}) [ #{parsed_schedule.original} ]"
    end

    def to_h
      {
        schedule: schedule,
        class_name: class_name,
        arguments: arguments
      }
    end

    private
      def using_solid_queue_adapter?
        job_class.queue_adapter_name.inquiry.solid_queue?
      end

      def perform_later_and_record(run_at:)
        RecurringExecution.record(key, run_at) { perform_later }
      end

      def perform_later
        job_class.perform_later(*arguments_with_kwargs)
      end

      def arguments_with_kwargs
        if arguments.last.is_a?(Hash)
          arguments[0...-1] + [ Hash.ruby2_keywords_hash(arguments.last) ]
        else
          arguments
        end
      end

      def parsed_schedule
        @parsed_schedule ||= Fugit.parse(schedule)
      end

      def job_class
        @job_class ||= class_name.safe_constantize
      end
  end
end
