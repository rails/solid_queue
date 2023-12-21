# frozen_string_literal: true

module SolidQueue
  class ReadyExecution < Execution
    scope :queued_as, ->(queue_name) { where(queue_name: queue_name) }

    assume_attributes_from_job

    class << self
      def claim(queue_list, limit, process_id)
        QueueSelector.new(queue_list, self).scoped_relations.flat_map do |queue_relation|
          select_and_lock(queue_relation, process_id, limit).tap do |locked|
            limit -= locked.size
          end
        end
      end

      private
        def select_and_lock(queue_relation, process_id, limit)
          return [] if limit <= 0

          transaction do
            job_ids = select_candidates(queue_relation, limit)
            lock_candidates(job_ids, process_id)
          end
        end

        def select_candidates(queue_relation, limit)
          queue_relation.ordered.limit(limit).non_blocking_lock.pluck(:job_id)
        end

        def lock_candidates(job_ids, process_id)
          return [] if job_ids.none?

          SolidQueue::ClaimedExecution.claiming(job_ids, process_id) do |claimed|
            where(job_id: claimed.pluck(:job_id)).delete_all
          end
        end
    end
  end
end
