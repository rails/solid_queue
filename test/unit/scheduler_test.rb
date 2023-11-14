require "test_helper"
require "active_support/testing/method_call_assertions"

class SchedulerTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::MethodCallAssertions

  setup do
    @scheduler = SolidQueue::Scheduler.new(polling_interval: 0.1, batch_size: 10)
  end

  teardown do
    @scheduler.stop if @scheduler.running?
  end

  test "polling queries are logged" do
    log = StringIO.new
    old_logger, ActiveRecord::Base.logger = ActiveRecord::Base.logger, ActiveSupport::Logger.new(log)
    old_silence_polling, SolidQueue.silence_polling = SolidQueue.silence_polling, false

    @scheduler.start(mode: :async)
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

    @scheduler.start(mode: :async)
    sleep 0.5

    assert_no_match /SELECT .* FROM .solid_queue_scheduled_executions. WHERE/, log.string
  ensure
    ActiveRecord::Base.logger = old_logger
    SolidQueue.silence_polling = old_silence_polling
  end
end
