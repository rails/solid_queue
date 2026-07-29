require "test_helper"

class SolidQueueTest < ActiveSupport::TestCase
  test "it has a version number" do
    assert SolidQueue::VERSION
  end

  test "time_zone defaults to the application's configured time zone, normalized to its IANA name" do
    assert_equal "Etc/UTC", SolidQueue.time_zone
  end
end
