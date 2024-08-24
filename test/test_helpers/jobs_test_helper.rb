module JobsTestHelper
  private

  def wait_for_jobs_to_finish_for(timeout = 1.second, except: [])
    wait_while_with_timeout(timeout) do
      skip_active_record_query_cache do
        SolidQueue::Job.where.not(active_job_id: Array(except).map(&:job_id)).where(finished_at: nil).any?
      end
    end
  end

  def assert_no_unfinished_jobs
    skip_active_record_query_cache do
      assert SolidQueue::Job.where(finished_at: nil).none?
    end
  end

  def wait_for_jobs_to_be_enqueued(count, timeout: 1.second)
    wait_while_with_timeout(timeout) do
      skip_active_record_query_cache do
        SolidQueue::Job.count < count
      end
    end
  end

  def assert_no_claimed_jobs
    skip_active_record_query_cache do
      assert SolidQueue::ClaimedExecution.none?
    end
  end
end
