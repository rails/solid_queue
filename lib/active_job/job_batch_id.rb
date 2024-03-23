# frozen_string_literal: true

# Inspired by active_job/core.rb docs
# https://github.com/rails/rails/blob/1c2529b9a6ba5a1eff58be0d0373d7d9d401015b/activejob/lib/active_job/core.rb#L136
module ActiveJob
  module JobBatchId
    extend ActiveSupport::Concern

    included do
      attr_accessor :batch_id
    end

    def serialize
      super.merge("batch_id" => batch_id)
    end

    def deserialize(job_data)
      super
      self.batch_id = job_data["batch_id"]
    end

    def batch
      @batch ||= SolidQueue::JobBatch.find_by(id: batch_id)
    end
  end
end
