# frozen_string_literal: true

require "test_helper"
require "active_support/log_subscriber/test_helper"

class LogSubscriberTest < ActiveSupport::TestCase
  include ActiveSupport::LogSubscriber::TestHelper

  teardown { ActiveSupport::LogSubscriber.log_subscribers.clear }

  test "unblock one job" do
    attach_log_subscriber
    instrument "release_blocked.solid_queue", job_id: 42, concurrency_key: "foo/1", released: true

    assert_match_logged :debug, "Release blocked job", "job_id: 42, concurrency_key: \"foo/1\", released: true"
  end

  test "unblock many jobs" do
    attach_log_subscriber
    instrument "unblock_batch.solid_queue", batch_size: 42

    assert_match_logged :debug, "Unblock jobs", "batch_size: 42"
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
