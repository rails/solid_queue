require "test_helper"
require "active_support/testing/method_call_assertions"

class WorkerTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::MethodCallAssertions

  setup do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 3, polling_interval: 0.2)
  end

  teardown do
    @worker.stop
    JobBuffer.clear
  end

  test "worker is registered as process" do
    @worker.start
    wait_for_registered_processes(1, timeout: 1.second)

    process = SolidQueue::Process.first
    assert_equal "Worker", process.kind
    assert_metadata process, { queues: "background", polling_interval: 0.2, thread_pool_size: 3 }
  end

  test "errors on polling are passed to on_thread_error and re-raised" do
    errors = Concurrent::Array.new

    original_on_thread_error, SolidQueue.on_thread_error = SolidQueue.on_thread_error, ->(error) { errors << error.message }
    previous_thread_report_on_exception, Thread.report_on_exception = Thread.report_on_exception, false

    SolidQueue::ReadyExecution.expects(:claim).raises(RuntimeError.new("everything is broken")).at_least_once

    AddToBufferJob.perform_later "hey!"

    worker = SolidQueue::Worker.new(queues: "background", threads: 3, polling_interval: 0.2).tap(&:start)
    sleep(1)

    assert_raises RuntimeError do
      worker.stop
    end

    assert_equal [ "everything is broken" ], errors
  ensure
    SolidQueue.on_thread_error = original_on_thread_error
    Thread.report_on_exception = previous_thread_report_on_exception
  end

  test "errors on claimed executions are reported via Rails error subscriber regardless of on_thread_error setting" do
    original_on_thread_error, SolidQueue.on_thread_error = SolidQueue.on_thread_error, nil

    subscriber = ErrorBuffer.new
    Rails.error.subscribe(subscriber)

    SolidQueue::ClaimedExecution::Result.expects(:new).raises(RuntimeError.new("everything is broken")).at_least_once

    AddToBufferJob.perform_later "hey!"

    @worker.start

    wait_for_jobs_to_finish_for(1.second)
    @worker.wake_up

    assert_equal 1, subscriber.errors.count
    assert_equal "everything is broken", subscriber.messages.first
  ensure
    Rails.error.unsubscribe(subscriber) if Rails.error.respond_to?(:unsubscribe)
    SolidQueue.on_thread_error = original_on_thread_error
  end

  test "claim and process more enqueued jobs than the pool size allows to process at once" do
    5.times do |i|
      StoreResultJob.perform_later(:paused, pause: 0.1.second)
    end

    3.times do |i|
      StoreResultJob.perform_later(:immediate)
    end

    @worker.start

    wait_for_jobs_to_finish_for(2.second)
    @worker.wake_up

    assert_equal 5, JobResult.where(queue_name: :background, status: "completed", value: :paused).count
    assert_equal 3, JobResult.where(queue_name: :background, status: "completed", value: :immediate).count
  end

  test "polling queries are logged" do
    log = StringIO.new
    with_active_record_logger(ActiveSupport::Logger.new(log)) do
      with_polling(silence: false) do
        @worker.start
        sleep 0.2
      end
    end

    assert_match /SELECT .* FROM .solid_queue_ready_executions. WHERE .solid_queue_ready_executions...queue_name./, log.string
  end

  test "polling queries can be silenced" do
    log = StringIO.new
    with_active_record_logger(ActiveSupport::Logger.new(log)) do
      with_polling(silence: true) do
        @worker.start
        sleep 0.2
      end
    end

    assert_no_match /SELECT .* FROM .solid_queue_ready_executions. WHERE .solid_queue_ready_executions...queue_name./, log.string
  end

  test "silencing polling queries when there's no Active Record logger" do
    with_active_record_logger(nil) do
      with_polling(silence: true) do
        @worker.start
        sleep 0.2
      end
    end

    @worker.stop
    wait_for_registered_processes(0, timeout: 1.second)
    assert_no_registered_processes
  end

  test "run inline" do
    worker = SolidQueue::Worker.new(queues: "*", threads: 3, polling_interval: 0.2)
    worker.mode = :inline

    5.times { |i| StoreResultJob.perform_later(:immediate) }

    worker.start

    assert_equal 5, JobResult.where(queue_name: :background, status: "completed", value: :immediate).count
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
