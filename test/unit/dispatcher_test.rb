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
    SolidQueue::Job.delete_all
    SolidQueue::Process.delete_all
  end

  test "dispatcher is registered as process" do
    @dispatcher.start
    wait_for_registered_processes(1, timeout: 1.second)

    process = SolidQueue::Process.first
    assert_equal "Dispatcher", process.kind
    assert_equal({ "polling_interval" => 0.1, "batch_size" => 10, "concurrency_maintenance_interval" => 600 }, process.metadata)
  end

  test "concurrency maintenance is optional" do
    no_concurrency_maintenance_dispatcher = SolidQueue::Dispatcher.new(polling_interval: 0.1, batch_size: 10, concurrency_maintenance: false)
    no_concurrency_maintenance_dispatcher.start

    wait_for_registered_processes(1, timeout: 1.second)

    process = SolidQueue::Process.first
    assert_equal "Dispatcher", process.kind
    assert_equal({ "polling_interval" => 0.1, "batch_size" => 10 }, process.metadata)

  ensure
    no_concurrency_maintenance_dispatcher.stop
  end

  test "recurring schedule" do
    recurring_task = { example_task: { class: "AddToBufferJob", schedule: "every hour", args: 42 } }
    with_recurring_schedule = SolidQueue::Dispatcher.new(concurrency_maintenance: false, recurring_tasks: recurring_task)

    with_recurring_schedule.start

    wait_for_registered_processes(1, timeout: 1.second)

    process = SolidQueue::Process.first
    assert_equal "Dispatcher", process.kind

    schedule_from_metadata = process.metadata["recurring_schedule"]
    assert_equal [ "example_task" ], schedule_from_metadata
  ensure
    with_recurring_schedule.stop
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
  end

  test "run more than one instance of the dispatcher without recurring tasks" do
    15.times do
      AddToBufferJob.set(wait: 0.2).perform_later("I'm scheduled")
    end
    assert_equal 15, SolidQueue::ScheduledExecution.count

    another_dispatcher = SolidQueue::Dispatcher.new(polling_interval: 0.1, batch_size: 10)

    @dispatcher.start
    another_dispatcher.start

    sleep 0.5

    assert_equal 0, SolidQueue::ScheduledExecution.count
    assert_equal 15, SolidQueue::ReadyExecution.count

  ensure
    another_dispatcher.stop
  end

  test "run more than one instance of the dispatcher with recurring tasks" do
    recurring_task = { example_task: { class: "AddToBufferJob", schedule: "every second", args: 42 } }
    dispatchers = 2.times.collect do
      SolidQueue::Dispatcher.new(concurrency_maintenance: false, recurring_tasks: recurring_task)
    end

    dispatchers.each(&:start)
    sleep 2
    dispatchers.each(&:stop)

    assert_equal SolidQueue::Job.count, SolidQueue::RecurringExecution.count
    run_at_times = SolidQueue::RecurringExecution.all.map(&:run_at).sort
    0.upto(run_at_times.length - 2) do |i|
      assert_equal 1, run_at_times[i + 1] - run_at_times[i]
    end
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
