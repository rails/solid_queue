# frozen_string_literal: true

module SolidQueue
  class Batch
    module Callbacks
      extend ActiveSupport::Concern

      included do
        %w[ finish success failure ].each do |callback_type|
          serialize "on_#{callback_type}", coder: JSON

          define_method("on_#{callback_type}=") do |callback|
            super serialize_callback(callback)
          end
        end
      end

      private
        def serialize_callback(value)
          if value.present?
            active_job = value.is_a?(ActiveJob::Base) ? value : value.new
            # We can pick up batch ids from context, but callbacks should never be considered a part of the batch
            active_job.batch_id = nil
            active_job.serialize
          end
        end

        def enqueue_callback_jobs
          if failed? then enqueue_callback_job(:on_failure)
          else
            enqueue_callback_job(:on_success)
          end

          enqueue_callback_job(:on_finish)
        end

        def enqueue_callback_job(callback_name)
          if callback = send(callback_name)
            active_job = ActiveJob::Base.deserialize(callback)
            active_job.callback_batch_id = id
            # Bypass the job class's adapter so callbacks stay in Solid Queue and
            # their enqueue stays in this transaction, while honoring enqueue callbacks.
            active_job.run_callbacks(:enqueue) do
              Job.enqueue(active_job, scheduled_at: active_job.scheduled_at || Time.current)
            end
          end
        end
    end
  end
end
