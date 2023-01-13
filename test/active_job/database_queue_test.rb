require "test_helper"

class ActiveJob::DatabaseQueueTest < ActiveSupport::TestCase
  test "it has a version number" do
    assert ActiveJob::DatabaseQueue::VERSION
  end
end
