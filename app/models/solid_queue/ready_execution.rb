module SolidQueue
  class ReadyExecution < Execution
    scope :ordered, -> { order(priority: :asc) }
    scope :not_paused, -> { where.not(queue_name: Pause.all_queue_names) }

    before_create :assume_attributes_from_job

    class << self
      def claim(queues, limit, process_id)
        transaction do
          candidates = select_candidates(queues, limit)
          lock(candidates, process_id)
        end
      end

      def queued_as(queues)
        QueueParser.new(queues, self).scoped_relation
      end

      private
        def select_candidates(queues, limit)
          queued_as(queues).not_paused.ordered.limit(limit).lock("FOR UPDATE SKIP LOCKED")
        end

        def lock(candidates, process_id)
          return [] if candidates.none?
          SolidQueue::ClaimedExecution.claiming(candidates, process_id) do |claimed|
            where(job_id: claimed.pluck(:job_id)).delete_all
          end
        end
    end

    def claim(process_id)
      transaction do
        SolidQueue::ClaimedExecution.claiming(self, process_id) do |claimed|
          delete if claimed.one?
        end
      end
    end
  end
end
