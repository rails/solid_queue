# frozen_string_literal: true

module SolidQueue
  class RecurringExecution < Execution
    class AlreadyRecorded < StandardError; end

    scope :clearable, -> { where.missing(:job) }

    class << self
      def create_or_insert!(**attributes)
        if connection.supports_insert_conflict_target?
          # PostgreSQL fails and aborts the current transaction when it hits a duplicate key conflict
          # during two concurrent INSERTs for the same value of an unique index. We need to explicitly
          # indicate unique_by to ignore duplicate rows by this value when inserting
          unless insert(attributes, unique_by: [ :task_key, :run_at ]).any?
            raise AlreadyRecorded
          end
        else
          create!(**attributes)
        end
      rescue ActiveRecord::RecordNotUnique
        raise AlreadyRecorded
      end

      def record(task_key, run_at, &block)
        transaction do
          block.call.tap do |active_job|
            if active_job && active_job.successfully_enqueued?
              create_or_insert!(job_id: active_job.provider_job_id, task_key: task_key, run_at: run_at)
            end
          end
        end
      end

      def clear_in_batches(batch_size: 500)
        loop do
          records_deleted = clearable.limit(batch_size).delete_all
          break if records_deleted == 0
        end
      end
    end
  end
end
