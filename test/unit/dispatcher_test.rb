require "test_helper"
require "active_support/testing/method_call_assertions"

class DispatcherTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::MethodCallAssertions

  setup do
    @dispatcher = SolidQueue::Dispatcher.new(polling_interval: 0.1, batch_size: 10)
  end

  teardown do
    @dispatcher.stop
  end

  test "polling queries are logged" do
    log = StringIO.new
    old_logger, ActiveRecord::Base.logger = ActiveRecord::Base.logger, ActiveSupport::Logger.new(log)
    old_silence_polling, SolidQueue.silence_polling = SolidQueue.silence_polling, false

    @dispatcher.start(mode: :async)
    sleep 0.5

    assert_match /SELECT .* FROM .solid_queue_scheduled_executions. WHERE/, log.string
  ensure
    ActiveRecord::Base.logger = old_logger
    SolidQueue.silence_polling = old_silence_polling
  end

  test "polling queries can be silenced" do
    log = StringIO.new
    old_logger, ActiveRecord::Base.logger = ActiveRecord::Base.logger, ActiveSupport::Logger.new(log)
    old_silence_polling, SolidQueue.silence_polling = SolidQueue.silence_polling, true

    @dispatcher.start(mode: :async)
    sleep 0.5

    assert_no_match /SELECT .* FROM .solid_queue_scheduled_executions. WHERE/, log.string
  ensure
    ActiveRecord::Base.logger = old_logger
    SolidQueue.silence_polling = old_silence_polling
  end

  test "run more than one instance of the dispatcher" do
    15.times do
      AddToBufferJob.set(wait: 0.2).perform_later("I'm scheduled")
    end
    assert_equal 15, SolidQueue::ScheduledExecution.count

    another_dispatcher = SolidQueue::Dispatcher.new(polling_interval: 0.1, batch_size: 10)
    @dispatcher.start(mode: :async)
    another_dispatcher.start(mode: :async)

    sleep 0.5

    assert_equal 0, SolidQueue::ScheduledExecution.count
    assert_equal 15, SolidQueue::ReadyExecution.count

    another_dispatcher.stop
  end
end
