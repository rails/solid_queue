require "test_helper"
require "active_support/testing/method_call_assertions"

class DispatcherTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::MethodCallAssertions

  self.use_transactional_tests = false

  setup do
    @dispatcher = SolidQueue::Dispatcher.new(polling_interval: 0.1, batch_size: 10)
  end

  teardown do
    @dispatcher.stop
  end

  test "dispatcher is registered as process" do
    @dispatcher.start
    wait_for_registered_processes(1, timeout: 1.second)

    process = SolidQueue::Process.first
    assert_equal "Dispatcher", process.kind
    assert_metadata process, { polling_interval: 0.1, batch_size: 10, concurrency_maintenance_interval: 600 }
  end

  test "concurrency maintenance is optional" do
    no_concurrency_maintenance_dispatcher = SolidQueue::Dispatcher.new(polling_interval: 0.1, batch_size: 10, concurrency_maintenance: false)
    no_concurrency_maintenance_dispatcher.start

    wait_for_registered_processes(1, timeout: 1.second)

    process = SolidQueue::Process.first
    assert_equal "Dispatcher", process.kind
    assert_metadata process, polling_interval: 0.1, batch_size: 10
  ensure
    no_concurrency_maintenance_dispatcher.stop
  end

  test "polling queries are logged" do
    log = StringIO.new
    with_active_record_logger(ActiveSupport::Logger.new(log)) do
      with_polling(silence: false) do
        @dispatcher.start
        sleep 0.2
      end
    end

    assert_match /SELECT .* FROM .solid_queue_scheduled_executions. WHERE/, log.string
  end

  test "polling queries can be silenced" do
    log = StringIO.new
    with_active_record_logger(ActiveSupport::Logger.new(log)) do
      with_polling(silence: true) do
        @dispatcher.start
        sleep 0.2
      end
    end

    assert_no_match /SELECT .* FROM .solid_queue_scheduled_executions. WHERE/, log.string
  end

  test "silencing polling queries when there's no Active Record logger" do
    with_active_record_logger(nil) do
      with_polling(silence: true) do
        @dispatcher.start
        sleep 0.2
      end
    end

    @dispatcher.stop
    wait_for_registered_processes(0, timeout: 1.second)
    assert_no_registered_processes
  end

  test "run more than one instance of the dispatcher" do
    15.times do
      AddToBufferJob.set(wait: 0.2).perform_later("I'm scheduled")
    end
    assert_equal 15, SolidQueue::ScheduledExecution.count

    another_dispatcher = SolidQueue::Dispatcher.new(polling_interval: 0.1, batch_size: 10)

    @dispatcher.start
    another_dispatcher.start

    wait_while_with_timeout(1.second) { SolidQueue::ScheduledExecution.any? }

    assert_equal 0, SolidQueue::ScheduledExecution.count
    assert_equal 15, SolidQueue::ReadyExecution.count
  ensure
    another_dispatcher&.stop
  end

  test "sleeps `0.seconds` between polls if there are ready to dispatch jobs" do
    dispatcher = SolidQueue::Dispatcher.new(polling_interval: 10, batch_size: 1)
    dispatcher.expects(:interruptible_sleep).with(0.seconds).at_least(3)
    dispatcher.expects(:interruptible_sleep).with(dispatcher.polling_interval).at_least_once

    3.times { AddToBufferJob.set(wait: 0.1).perform_later("I'm scheduled") }
    assert_equal 3, SolidQueue::ScheduledExecution.count
    sleep 0.1

    dispatcher.start
    wait_while_with_timeout(1.second) { SolidQueue::ScheduledExecution.any? }

    assert_equal 0, SolidQueue::ScheduledExecution.count
    assert_equal 3, SolidQueue::ReadyExecution.count
  end

  test "sleeps `polling_interval` between polls if there are no un-dispatched jobs" do
    dispatcher = SolidQueue::Dispatcher.new(polling_interval: 10, batch_size: 1)
    dispatcher.expects(:interruptible_sleep).with(0.seconds).never
    dispatcher.expects(:interruptible_sleep).with(dispatcher.polling_interval).at_least_once
    dispatcher.start
    sleep 0.1
  end

  private
    def with_polling(silence:)
      old_silence_polling, SolidQueue.silence_polling = SolidQueue.silence_polling, silence
      yield
    ensure
      SolidQueue.silence_polling = old_silence_polling
    end

    def with_active_record_logger(logger)
      old_logger, ActiveRecord::Base.logger = ActiveRecord::Base.logger, logger
      yield
    ensure
      ActiveRecord::Base.logger = old_logger
    end
end
