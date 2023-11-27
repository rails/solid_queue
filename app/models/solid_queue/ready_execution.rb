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
            candidates = select_candidates(queue_relation, limit)
            lock(candidates, process_id)
          end
        end

        def select_candidates(queue_relation, limit)
          queue_relation.ordered.limit(limit).lock("FOR UPDATE SKIP LOCKED").pluck(:job_id)
        end

        def lock(candidates, process_id)
          return [] if candidates.none?
          SolidQueue::ClaimedExecution.claiming(candidates, process_id) do |claimed|
            where(job_id: claimed.pluck(:job_id)).delete_all
          end
        end
    end
  end
end
