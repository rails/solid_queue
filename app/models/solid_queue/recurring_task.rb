# frozen_string_literal: true

require "fugit"

module SolidQueue
  class RecurringTask < Record
    serialize :arguments, coder: Arguments, default: []

    validate :supported_schedule
    validate :ensure_command_or_class_present
    validate :existing_job_class

    scope :static, -> { where(static: true) }

    has_many :recurring_executions, foreign_key: :task_key, primary_key: :key

    mattr_accessor :default_job_class
    self.default_job_class = RecurringJob

    class << self
      def wrap(args)
        args.is_a?(self) ? args : from_configuration(args.first, **args.second)
      end

      def from_configuration(key, **options)
        new \
          key: key,
          class_name: options[:class],
          command: options[:command],
          arguments: options[:args],
          schedule: options[:schedule],
          queue_name: options[:queue].presence,
          priority: options[:priority].presence,
          description: options[:description],
          static: true
      end

      def create_or_update_all(tasks)
        if connection.supports_insert_conflict_target?
          # PostgreSQL fails and aborts the current transaction when it hits a duplicate key conflict
          # during two concurrent INSERTs for the same value of an unique index. We need to explicitly
          # indicate unique_by to ignore duplicate rows by this value when inserting
          upsert_all tasks.map(&:attributes_for_upsert), unique_by: :key
        else
          upsert_all tasks.map(&:attributes_for_upsert)
        end
      end
    end

    def delay_from_now
      [ (next_time - Time.current).to_f, 0 ].max
    end

    def next_time
      parsed_schedule.next_time.utc
    end

    def previous_time
      parsed_schedule.previous_time.utc
    end

    def last_enqueued_time
      if recurring_executions.loaded?
        recurring_executions.map(&:run_at).max
      else
        recurring_executions.maximum(:run_at)
      end
    end

    def enqueue(at:)
      SolidQueue.instrument(:enqueue_recurring_task, task: key, at: at) do |payload|
        active_job = if using_solid_queue_adapter?
          enqueue_and_record(run_at: at)
        else
          payload[:other_adapter] = true

          perform_later.tap do |job|
            unless job.successfully_enqueued?
              payload[:enqueue_error] = job.enqueue_error&.message
            end
          end
        end

        active_job.tap do |enqueued_job|
          payload[:active_job_id] = enqueued_job.job_id
        end
      rescue RecurringExecution::AlreadyRecorded
        payload[:skipped] = true
        false
      rescue Job::EnqueueError => error
        payload[:enqueue_error] = error.message
        false
      end
    end

    def to_s
      "#{class_name}.perform_later(#{arguments.map(&:inspect).join(",")}) [ #{parsed_schedule.original} ]"
    end

    def attributes_for_upsert
      attributes.without("id", "created_at", "updated_at")
    end

    private
      def supported_schedule
        unless parsed_schedule.instance_of?(Fugit::Cron)
          errors.add :schedule, :unsupported, message: "is not a supported recurring schedule"
        end
      end

      def ensure_command_or_class_present
        unless command.present? || class_name.present?
          errors.add :base, :command_and_class_blank, message: "either command or class_name must be present"
        end
      end

      def existing_job_class
        if class_name.present? && job_class.nil?
          errors.add :class_name, :undefined, message: "doesn't correspond to an existing class"
        end
      end

      def using_solid_queue_adapter?
        job_class.queue_adapter_name.inquiry.solid_queue?
      end

      def enqueue_and_record(run_at:)
        RecurringExecution.record(key, run_at) do
          job_class.new(*arguments_with_kwargs).set(enqueue_options).tap do |active_job|
            active_job.run_callbacks(:enqueue) do
              Job.enqueue(active_job)
            end
          end
        end
      end

      def perform_later
        job_class.new(*arguments_with_kwargs).tap do |active_job|
          active_job.enqueue(enqueue_options)
        end
      end

      def arguments_with_kwargs
        if class_name.nil?
          command
        elsif arguments.last.is_a?(Hash)
          arguments[0...-1] + [ Hash.ruby2_keywords_hash(arguments.last) ]
        else
          arguments
        end
      end


      def parsed_schedule
        @parsed_schedule ||= Fugit.parse(schedule)
      end

      def job_class
        @job_class ||= class_name.present? ? class_name.safe_constantize : self.class.default_job_class
      end

      def enqueue_options
        { queue: queue_name, priority: priority }.compact
      end
  end
end
