# frozen_string_literal: true

module SolidQueue
  class Queue
    attr_accessor :name

    class << self
      def all
        Job.select(:queue_name).distinct.collect do |job|
          new(job.queue_name)
        end
      end

      def find_by_name(name)
        new(name)
      end
    end

    def initialize(name)
      @name = name
    end

    def paused?
      Pause.exists?(queue_name: name)
    end

    def pause
      Pause.create_or_find_by!(queue_name: name)
    end

    def resume
      Pause.where(queue_name: name).delete_all
    end

    def clear
      ReadyExecution.queued_as(name).discard_all_in_batches
    end

    def size
      @size ||= ReadyExecution.queued_as(name).count
    end

    def latency
      @latency ||= begin
        now = Time.current
        oldest_enqueued_at = ReadyExecution.queued_as(name).minimum(:created_at) || now

        (now - oldest_enqueued_at).to_i
      end
    end

    def human_latency
      ActiveSupport::Duration.build(latency).inspect
    end

    def ==(queue)
      name == queue.name
    end
    alias_method :eql?, :==

    def hash
      name.hash
    end
  end
end
