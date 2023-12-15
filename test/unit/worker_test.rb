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

  test "errors on claiming executions are reported via Rails error subscriber regardless of on_thread_error setting" do
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

    wait_for_jobs_to_finish_for(1.second)
    @worker.wake_up

    assert_equal 5, JobResult.where(queue_name: :background, status: "completed", value: :paused).count
    assert_equal 3, JobResult.where(queue_name: :background, status: "completed", value: :immediate).count
  end

  test "polling queries are logged" do
    log = StringIO.new
    old_logger, ActiveRecord::Base.logger = ActiveRecord::Base.logger, ActiveSupport::Logger.new(log)
    old_silence_polling, SolidQueue.silence_polling = SolidQueue.silence_polling, false

    @worker.start
    sleep 0.2

    assert_match /SELECT .* FROM .solid_queue_ready_executions. WHERE .solid_queue_ready_executions...queue_name./, log.string
  ensure
    ActiveRecord::Base.logger = old_logger
    SolidQueue.silence_polling = old_silence_polling
  end

  test "polling queries can be silenced" do
    log = StringIO.new
    old_logger, ActiveRecord::Base.logger = ActiveRecord::Base.logger, ActiveSupport::Logger.new(log)
    old_silence_polling, SolidQueue.silence_polling = SolidQueue.silence_polling, true

    @worker.start
    sleep 0.2

    assert_no_match /SELECT .* FROM .solid_queue_ready_executions. WHERE .solid_queue_ready_executions...queue_name./, log.string
  ensure
    ActiveRecord::Base.logger = old_logger
    SolidQueue.silence_polling = old_silence_polling
  end
end
