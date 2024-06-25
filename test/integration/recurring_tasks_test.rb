# frozen_string_literal: true

require "test_helper"

class RecurringTasksTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @pid = run_supervisor_as_fork
    # 1 supervisor + 2 workers + 1 dispatcher
    wait_for_registered_processes(4, timeout: 3.second)
  end

  teardown do
    terminate_process(@pid) if process_exists?(@pid)

    SolidQueue::Process.destroy_all
    SolidQueue::Job.destroy_all
    JobResult.delete_all
  end

  test "enqueue and process periodic tasks" do
    wait_for_jobs_to_be_enqueued(2, timeout: 2.seconds)
    wait_for_jobs_to_finish_for(2.seconds)

    terminate_process(@pid)

    skip_active_record_query_cache do
      assert SolidQueue::Job.count >= 2
      SolidQueue::Job.all.each do |job|
        assert_equal "periodic_store_result", job.recurring_execution.task_key
        assert_equal "StoreResultJob", job.class_name
      end

      assert_equal 2, JobResult.count
      JobResult.all.each do |result|
        assert_equal "custom_status", result.status
        assert_equal "42", result.value
      end
    end
  end

  private
    def wait_for_jobs_to_be_enqueued(count, timeout: 1.second)
      wait_while_with_timeout(timeout) { SolidQueue::Job.count < count }
    end
end
