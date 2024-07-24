# frozen_string_literal: true

require "test_helper"
require "active_support/log_subscriber/test_helper"

class LogSubscriberTest < ActiveSupport::TestCase
  include ActiveSupport::LogSubscriber::TestHelper

  teardown { ActiveSupport::LogSubscriber.log_subscribers.clear }

  def set_logger(logger)
    SolidQueue.logger = logger
  end

  test "unblock one job" do
    attach_log_subscriber
    instrument "release_blocked.solid_queue", job_id: 42, concurrency_key: "foo/1", released: true

    assert_match_logged :debug, "Release blocked job", "job_id: 42, concurrency_key: \"foo/1\", released: true"
  end

  test "unblock many jobs" do
    attach_log_subscriber
    instrument "release_many_blocked.solid_queue", limit: 42, size: 10

    assert_match_logged :debug, "Unblock jobs", "limit: 42, size: 10"
  end

  test "recurring task enqueued succesfully" do
    attach_log_subscriber
    time = Time.now
    instrument "enqueue_recurring_task.solid_queue", task: :example_task, active_job_id: "b944ddbc-6a37-43c0-b661-4b56e57195f5", at: time

    assert_match_logged :info, "Enqueued recurring task", "task: :example_task, active_job_id: \"b944ddbc-6a37-43c0-b661-4b56e57195f5\", at: \"#{time.iso8601}\""
  end

  test "recurring task skipped" do
    attach_log_subscriber
    time = Time.now
    instrument "enqueue_recurring_task.solid_queue", task: :example_task, skipped: true, at: time

    assert_match_logged :info, "Skipped recurring task – already dispatched", "task: :example_task, at: \"#{time.iso8601}\""
  end

  test "error enqueuing recurring task" do
    attach_log_subscriber
    time = Time.now
    instrument "enqueue_recurring_task.solid_queue", task: :example_task, enqueue_error: "Everything is broken", at: time

    assert_match_logged :info, "Error enqueuing recurring task", "task: :example_task, enqueue_error: \"Everything is broken\", at: \"#{time.iso8601}\""
  end

  test "deregister process" do
    process = SolidQueue::Process.register(kind: "Worker", pid: 42, hostname: "localhost")
    last_heartbeat_at = process.last_heartbeat_at.iso8601

    attach_log_subscriber
    instrument "deregister_process.solid_queue", process: process, pruned: false

    assert_match_logged :info, "Deregister Worker", "process_id: #{process.id}, pid: 42, hostname: \"localhost\", last_heartbeat_at: \"#{last_heartbeat_at}\", claimed_size: 0, pruned: false"
  end

  private
    def attach_log_subscriber
      ActiveSupport::LogSubscriber.attach_to :solid_queue, SolidQueue::LogSubscriber.new
    end

    def instrument(...)
      ActiveSupport::Notifications.instrument(...)
      wait
    end

    def assert_match_logged(level, action, attributes)
      assert_equal 1, @logger.logged(level).size
      assert_match /SolidQueue-[\d.]+ #{action} \(\d+\.\d+ms\)  #{Regexp.escape(attributes)}/, @logger.logged(level).last
    end
end
