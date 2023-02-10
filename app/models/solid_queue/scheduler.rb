class SolidQueue::Scheduler
  attr_accessor :batch_size

  def initialize(**options)
    @batch_size = options[:batch_size] || 500
  end

  def start
    @stopping = false

    @thread = Thread.new { dispatch }
  end

  def dispatch
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

  def stop
    @stopping = true
    wait
  end

  def stopping?
    @stopping
  end

  private
    def wait
      @thread&.join
    end
end
