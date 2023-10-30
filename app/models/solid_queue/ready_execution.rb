module SolidQueue
  class ReadyExecution < Execution
    scope :ordered, -> { order(priority: :asc) }
    scope :not_paused, -> { where.not(queue_name: Pause.all_queue_names) }

    before_create :assume_attributes_from_job

    class << self
      def claim(queues, limit)
        transaction do
          candidates = select_candidates(queues, limit)
          lock(candidates)
        end
      end

      def queued_as(queues)
        QueueParser.new(queues, self).scoped_relation
      end

      private
        def select_candidates(queues, limit)
          queued_as(queues).not_paused.ordered.limit(limit).lock("FOR UPDATE SKIP LOCKED")
        end

        def lock(candidates)
          return [] if candidates.none?

          SolidQueue::ClaimedExecution.claiming(candidates) do |claimed|
            where(job_id: claimed.pluck(:job_id)).delete_all
          end
        end
    end

    def claim
      transaction do
        SolidQueue::ClaimedExecution.claiming(self) do |claimed|
          delete if claimed.one?
        end
      end
    end
  end
end
