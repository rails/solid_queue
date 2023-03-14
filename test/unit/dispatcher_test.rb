require "test_helper"
require "active_support/testing/method_call_assertions"

class DispatcherTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::MethodCallAssertions

  setup do
    @jobs = SolidQueue::Job.where(queue_name: "fixtures")
    @jobs.each(&:prepare_for_execution)

    @dispatcher = SolidQueue::Dispatcher.new(queue: "fixtures", worker_count: 3, polling_interval: 1)
  end

  teardown do
    @dispatcher.stop if @dispatcher.running?
    JobBuffer.clear
  end

  test "report errors on claiming executions via Rails error subscriber" do
    subscriber = ErrorBuffer.new
    Rails.error.subscribe(subscriber)

    SolidQueue::ClaimedExecution.any_instance.expects(:update!).raises(RuntimeError.new("everything is broken")).at_least_once

    AddToBufferJob.perform_later "hey!"

    @dispatcher.queue = "background"
    @dispatcher.start

    wait_for_jobs_to_finish_for(0.5.second)

    assert_equal 1, subscriber.errors.count
    assert_equal "everything is broken", subscriber.messages.first
  ensure
    Rails.error.unsubscribe(subscriber) if Rails.error.respond_to?(:unsubscribe)
  end

  test "shut down before limit of executions per run is reached" do
    with_execution_limit_per_dispatch_run(4) do
      @dispatcher.start

      wait_for_jobs_to_finish_for(0.5.second)

      assert_not @dispatcher.running?
      assert_equal 4, SolidQueue::Job.in_queue("fixtures").finished.count
    end
  end

  test "continues running all jobs if limit of executions per run is not reached" do
    with_execution_limit_per_dispatch_run(SolidQueue::Job.in_queue("fixtures").count + 1) do
      @dispatcher.start

      wait_for_jobs_to_finish_for(0.5.second)

      assert @dispatcher.running?
      assert_equal SolidQueue::Job.in_queue("fixtures").count, SolidQueue::Job.in_queue("fixtures").finished.count
    end
  end

  private
    def with_execution_limit_per_dispatch_run(limit)
      previous_limit, SolidQueue.execution_limit_per_dispatch_run = SolidQueue.execution_limit_per_dispatch_run, limit

      yield
    ensure
      SolidQueue.execution_limit_per_dispatch_run = previous_limit
    end
end
