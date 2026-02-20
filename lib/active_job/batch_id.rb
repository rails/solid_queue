# frozen_string_literal: true

# Inspired by active_job/core.rb docs
# https://github.com/rails/rails/blob/1c2529b9a6ba5a1eff58be0d0373d7d9d401015b/activejob/lib/active_job/core.rb#L136
module ActiveJob
  module BatchId
    extend ActiveSupport::Concern

    included do
      attr_accessor :batch_id
      attr_accessor :callback_batch_id
    end

    def initialize(*arguments, **kwargs)
      super
      self.batch_id = SolidQueue::Batch.current_batch_id if solid_queue_job?
    end

    def serialize
      super.merge("batch_id" => batch_id, "callback_batch_id" => callback_batch_id)
    end

    def deserialize(job_data)
      super
      self.batch_id = job_data["batch_id"]
      self.callback_batch_id = job_data["callback_batch_id"]
    end

    def batch
      @batch ||= SolidQueue::Batch.find_by(id: callback_batch_id || batch_id)
    end

    private

      def solid_queue_job?
        self.class.queue_adapter_name == "solid_queue"
      end
  end
end
