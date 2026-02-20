require "test_helper"
require "active_support/testing/method_call_assertions"

class ConnectionClearingTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::MethodCallAssertions
  include JobsTestHelper

  self.use_transactional_tests = false

  test "clears ActiveRecord connections when flag enabled" do
    old_flag, SolidQueue.clear_connections_after_job = SolidQueue.clear_connections_after_job, true

    ActiveRecord::Base.expects(:clear_active_connections!).at_least_once

    AddToBufferJob.perform_later "clear"

    worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
    worker.start
    wait_for_jobs_to_finish_for(2.seconds)
    worker.stop
  ensure
    SolidQueue.clear_connections_after_job = old_flag
  end

  test "does not clear ActiveRecord connections when flag disabled" do
    old_flag, SolidQueue.clear_connections_after_job = SolidQueue.clear_connections_after_job, false

    ActiveRecord::Base.expects(:clear_active_connections!).never

    AddToBufferJob.perform_later "noclear"

    worker = SolidQueue::Worker.new(queues: "background", threads: 1, polling_interval: 0.1)
    worker.start
    wait_for_jobs_to_finish_for(2.seconds)
    worker.stop
  ensure
    SolidQueue.clear_connections_after_job = old_flag
  end
end
