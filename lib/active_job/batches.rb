# frozen_string_literal: true

module ActiveJob
  module Batches
    extend ActiveSupport::Concern

    included do
      attr_accessor :batch_id
    end

    class_methods do
      def perform_batch(job_args_array, **batch_options)
        return if job_args_array.empty?

        jobs = job_args_array.map do |args|
          # Handle both array and hash arguments
          if args.is_a?(Hash)
            new(**args)
          else
            new(*Array(args))
          end
        end

        SolidQueue::Batch.enqueue(jobs, **batch_options)
      end

      def perform_batch_later(job_args_array, **batch_options)
        perform_batch(job_args_array, **batch_options)
      end

      def perform_batch_at(scheduled_at, job_args_array, **batch_options)
        return if job_args_array.empty?

        jobs = job_args_array.map do |args|
          job = if args.is_a?(Hash)
            new(**args)
          else
            new(*Array(args))
          end
          job.scheduled_at = scheduled_at
          job
        end

        SolidQueue::Batch.enqueue(jobs, **batch_options)
      end
    end

    def batch
      return nil unless batch_id.present?
      @batch ||= SolidQueue::Batch.find_by(batch_id: batch_id)
    end

    def in_batch?
      batch_id.present?
    end

    def batch_siblings
      return self.class.none unless in_batch?

      batch.jobs.map do |job|
        ActiveJob::Base.deserialize(job.arguments)
      rescue
        nil
      end.compact
    end

    def batch_progress
      batch&.progress_percentage || 0
    end

    def batch_status
      batch&.status
    end

    def batch_finished?
      batch&.finished? || false
    end

    def serialize
      super.tap do |job_data|
        job_data["batch_id"] = batch_id if batch_id.present?
      end
    end

    def deserialize(job_data)
      super
      self.batch_id = job_data["batch_id"]
    end
  end

  class Base
    include Batches
  end
end
