# frozen_string_literal: true

require "test_helper"

class ConcurrencyMaintenanceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @result = JobResult.create!(queue_name: "default", status: "")
  end

  # Regression for https://github.com/rails/solid_queue/issues/735:
  # After a claimed concurrency-limited job is released back to ready (non-graceful
  # shutdown), its semaphore may still be expired. Expiring that semaphore and
  # unblocking the next job while the released job remains ready leaves two ready
  # jobs for the same key — workers can then claim both and violate the limit.
  test "expire_semaphores does not drop locks still held by ready jobs" do
    claimed_job, blocked_job = enqueue_claimed_and_blocked_pair

    claimed_job.claimed_execution.release

    assert claimed_job.reload.ready?
    assert blocked_job.reload.blocked?

    semaphore = SolidQueue::Semaphore.find_by!(key: claimed_job.concurrency_key)
    assert_equal 0, semaphore.value
    semaphore.update!(expires_at: 1.minute.ago)

    maintenance = SolidQueue::Dispatcher::ConcurrencyMaintenance.new(60, 100)
    maintenance.send(:expire_semaphores)
    maintenance.send(:unblock_blocked_executions)

    skip_active_record_query_cache do
      assert SolidQueue::Semaphore.exists?(key: claimed_job.concurrency_key),
        "semaphore held by a ready job must not be expired away"
      assert claimed_job.reload.ready?
      assert blocked_job.reload.blocked?
      assert_equal 1, SolidQueue::ReadyExecution.count
      assert_equal 1, SolidQueue::BlockedExecution.count
    end
  end

  test "perform expires abandoned locks and unblocks waiting jobs" do
    first = NonOverlappingUpdateResultJob.perform_later(@result, name: "A")
    first_job = wait_for_solid_queue_job(first)

    # Abandon the ready execution without releasing the concurrency lock,
    # leaving an expired semaphore with blocked work waiting behind it.
    SolidQueue::ReadyExecution.find_by!(job_id: first_job.id).delete
    assert_equal 0, SolidQueue::Semaphore.find_by!(key: first_job.concurrency_key).value

    second = NonOverlappingUpdateResultJob.perform_later(@result, name: "B")
    second_job = wait_for_solid_queue_job(second)
    assert second_job.blocked?

    SolidQueue::Semaphore.where(key: first_job.concurrency_key).update_all(expires_at: 1.minute.ago)
    SolidQueue::BlockedExecution.update_all(expires_at: 1.minute.ago)

    SolidQueue::Dispatcher::ConcurrencyMaintenance.perform(batch_size: 100)

    skip_active_record_query_cache do
      assert second_job.reload.ready?
      assert_equal 0, SolidQueue::BlockedExecution.count
    end
  end

  test "releasing a claimed job extends its concurrency lock expiry" do
    claimed_job, _blocked_job = enqueue_claimed_and_blocked_pair

    semaphore = SolidQueue::Semaphore.find_by!(key: claimed_job.concurrency_key)
    semaphore.update!(expires_at: 1.second.from_now)
    previous_expiry = semaphore.reload.expires_at

    claimed_job.claimed_execution.release

    skip_active_record_query_cache do
      assert claimed_job.reload.ready?
      assert_operator SolidQueue::Semaphore.find_by!(key: claimed_job.concurrency_key).expires_at, :>, previous_expiry
    end
  end

  private
    def enqueue_claimed_and_blocked_pair
      first = NonOverlappingUpdateResultJob.perform_later(@result, name: "A", pause: 30.seconds)
      first_job = wait_for_solid_queue_job(first)

      process = SolidQueue::Process.register(kind: "Worker", pid: Process.pid, name: "maintenance-test-#{SecureRandom.hex(4)}")
      claimed = SolidQueue::ReadyExecution.claim("*", 1, process.id)
      assert_equal [ first_job.id ], claimed.map(&:job_id)

      second = NonOverlappingUpdateResultJob.perform_later(@result, name: "B")
      blocked_job = wait_for_solid_queue_job(second)
      assert blocked_job.blocked?

      [ first_job.reload, blocked_job ]
    end

    def wait_for_solid_queue_job(active_job)
      wait_while_with_timeout!(2.seconds) do
        SolidQueue::Job.find_by(active_job_id: active_job.job_id).nil?
      end
      SolidQueue::Job.find_by!(active_job_id: active_job.job_id)
    end
end
