# frozen_string_literal: true

class SolidQueue::Scheduler
  include SolidQueue::Runnable

  attr_accessor :batch_size, :polling_interval

  def initialize(**options)
    options = options.dup.with_defaults(SolidQueue::Configuration::SCHEDULER_DEFAULTS)

    @batch_size = options[:batch_size]
    @polling_interval = options[:polling_interval]
  end

  def inspect
    "Scheduler(batch_size=#{batch_size}, polling_interval=#{polling_interval})"
  end
  alias to_s inspect

  private
    def run
      batch = SolidQueue::ScheduledExecution.next_batch(batch_size)

      if batch.size > 0
        SolidQueue::ScheduledExecution.prepare_batch(batch)
      else
        interruptable_sleep(polling_interval)
      end
    end
end
