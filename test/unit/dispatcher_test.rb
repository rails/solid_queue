require "test_helper"
require "active_support/testing/method_call_assertions"

class DispatcherTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::MethodCallAssertions

  setup do
    @dispatcher = SolidQueue::Dispatcher.new(queue_name: "background", worker_count: 3, polling_interval: 1)
  end

  teardown do
    @dispatcher.stop if @dispatcher.running?
    JobBuffer.clear
  end

  test "errors on claiming executions are reported via Rails error subscriber" do
    subscriber = ErrorBuffer.new
    Rails.error.subscribe(subscriber)

    SolidQueue::ClaimedExecution.any_instance.expects(:update!).raises(RuntimeError.new("everything is broken"))

    AddToBufferJob.perform_later "hey!"

    @dispatcher.start(mode: :async)

    wait_for_jobs_to_finish_for(0.5.second)

    assert_equal 1, subscriber.errors.count
    assert_equal "everything is broken", subscriber.messages.first
  ensure
    Rails.error.unsubscribe(subscriber) if Rails.error.respond_to?(:unsubscribe)
  end
end
