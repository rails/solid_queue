class SolidQueue::Scheduler
  include SolidQueue::Runnable

  attr_accessor :batch_size

  def initialize(**options)
    @batch_size = options[:batch_size] || 500
  end

  private
    def run
      loop do
        break if stopping?

        batch = SolidQueue::ScheduledExecution.next_batch(batch_size)

        if batch.size > 0
          SolidQueue::ScheduledExecution.prepare_batch(batch)
        else
          sleep(1)
        end
      end
    end
end
