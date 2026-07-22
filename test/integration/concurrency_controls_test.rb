# frozen_string_literal: true

require "test_helper"

class ConcurrencyControlsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    # Previous tests may leave forked workers briefly alive; those can still write to
    # JobResult rows whose primary keys get reused by create! below (e.g. overwriting
    # status with StoreResultJob's default "completed").
    wait_for_registered_processes(0, timeout: 5.seconds)
    destroy_records

    default_worker = { queues: "default", polling_interval: 0.1, processes: 3, threads: 2 }
    dispatcher = { polling_interval: 0.1, batch_size: 200, concurrency_maintenance_interval: 1 }

    @pid = run_supervisor_as_fork(workers: [ default_worker ], dispatchers: [ dispatcher ])
    wait_for_registered_processes(5, timeout: 3.seconds) # 3 workers + dispatcher + supervisor

    @result = JobResult.create!(queue_name: "default", status: "")
  end

  teardown do
    if @pid && process_exists?(@pid)
      terminate_process(@pid)
    end
    wait_for_registered_processes(0, timeout: 5.seconds)
    destroy_records
  end

  test "run several conflicting jobs over the same record without overlapping" do
    ("A".."F").each do |name|
      NonOverlappingUpdateResultJob.perform_later(@result, name: name, pause: 0.2.seconds)
    end

    ("G".."K").each do |name|
      NonOverlappingUpdateResultJob.perform_later(@result, name: name)
    end

    wait_for_jobs_to_finish_for(5.seconds)
    assert_no_unfinished_jobs

    assert_stored_sequence @result, ("A".."K").to_a
  end

  test "schedule several conflicting jobs over the same record sequentially" do
    # "000" isn't concurrency-limited, so it runs alongside A. Both read @result
    # while it's still empty; "000" writes "s000c000" partway through A's run, but
    # A pauses much longer and saves last of the two, overwriting it. A is
    # scheduled well ahead of B–K so it reliably holds the semaphore first, and
    # the rest of the chain builds only on A's clean write — so "000" never
    # survives in the final result.
    UpdateResultJob.set(wait: 0.1.seconds).perform_later(@result, name: "000", pause: 1.second)

    NonOverlappingUpdateResultJob.set(wait: 0.1.seconds).perform_later(@result, name: "A", pause: 2.5.seconds)

    ("B".."F").each_with_index do |name, i|
      NonOverlappingUpdateResultJob.set(wait: (1 + i * 0.1).seconds).perform_later(@result, name: name, pause: 0.1.seconds)
    end

    ("G".."K").each_with_index do |name, i|
      NonOverlappingUpdateResultJob.set(wait: (1.5 + i * 0.1).seconds).perform_later(@result, name: name)
    end

    wait_for_jobs_to_finish_for(15.seconds)
    assert_no_unfinished_jobs

    assert_stored_sequence @result, ("A".."K").to_a
  end

  test "run several jobs over the same record limiting concurrency" do
    # ThrottledUpdateResultJob has a concurrency limit of 3, so A, B and C run
    # together — all reading @result while it's still empty — and D–H block. A
    # and B finish quickly, freeing slots that drain D–H; C reads the empty
    # status and pauses far longer than everyone else, so it saves last and its
    # write (built on the empty status) overwrites all the others, leaving "C".
    assert_no_difference -> { SolidQueue::BlockedExecution.count } do
      ThrottledUpdateResultJob.perform_later(@result, name: "A", pause: 0.5.seconds)
      ThrottledUpdateResultJob.perform_later(@result, name: "B", pause: 0.5.seconds)
      ThrottledUpdateResultJob.perform_later(@result, name: "C", pause: 3.seconds)
    end

    wait_for(timeout: 2.seconds) { SolidQueue::ClaimedExecution.count >= 3 }

    assert_difference -> { SolidQueue::BlockedExecution.count }, +5 do
      ("D".."H").each do |name|
        ThrottledUpdateResultJob.perform_later(@result, name: name, pause: 0.01.seconds)
      end
    end

    wait_for_jobs_to_finish_for(15.seconds)
    assert_no_unfinished_jobs

    assert_stored_sequence(@result, [ "C" ])
  end

  test "run several jobs over the same record sequentially, with some of them failing" do
    ("A".."F").each_with_index do |name, i|
      # A, C, E will fail, for i= 0, 2, 4
      NonOverlappingUpdateResultJob.perform_later(@result, name: name, pause: 0.2.seconds, exception: (ExpectedTestError if i.even?))
    end

    ("G".."K").each do |name|
      NonOverlappingUpdateResultJob.perform_later(@result, name: name)
    end

    wait_for_jobs_to_finish_for(15.seconds)
    assert_equal 3, SolidQueue::FailedExecution.count

    assert_stored_sequence @result, [ "B", "D", "F" ] + ("G".."K").to_a
  end

  test "rely on dispatcher to unblock blocked executions with an available semaphore" do
    # Simulate a scenario where we got an available semaphore and some stuck jobs
    job = NonOverlappingUpdateResultJob.perform_later(@result, name: "A")

    wait_for_jobs_to_finish_for(5.seconds)
    assert_no_unfinished_jobs

    wait_while_with_timeout(1.second) { SolidQueue::Semaphore.where(value: 0).any? }
    # Lock the semaphore so we can enqueue jobs and leave them blocked
    skip_active_record_query_cache do
      assert SolidQueue::Semaphore.wait(job)
    end

    # Now enqueue more jobs under that same key. They'll be all locked
    assert_difference -> { SolidQueue::BlockedExecution.count }, +10 do
      ("B".."K").each do |name|
        NonOverlappingUpdateResultJob.perform_later(@result, name: name)
      end
    end

    # Then unlock the semaphore and expire the jobs: this would be as if the first job had
    # released the semaphore but hadn't unblocked any jobs
    SolidQueue::BlockedExecution.update_all(expires_at: 15.minutes.ago)
    assert SolidQueue::Semaphore.signal(job)

    # And wait for the dispatcher to release the jobs
    wait_for_jobs_to_finish_for(5.seconds)
    assert_no_unfinished_jobs

    assert_stored_sequence @result, ("A".."K").to_a
  end

  test "rely on dispatcher to unblock blocked executions with an expired semaphore" do
    # Simulate a scenario where we got an available semaphore and some stuck jobs
    job = NonOverlappingUpdateResultJob.perform_later(@result, name: "A")
    wait_for_jobs_to_finish_for(5.seconds)
    assert_no_unfinished_jobs

    wait_while_with_timeout(1.second) { SolidQueue::Semaphore.where(value: 0).any? }
    # Lock the semaphore so we can enqueue jobs and leave them blocked
    skip_active_record_query_cache do
      assert SolidQueue::Semaphore.wait(job)
    end

    # Now enqueue more jobs under that same key. They'll be all locked
    assert_difference -> { SolidQueue::BlockedExecution.count }, +10 do
      ("B".."K").each do |name|
        NonOverlappingUpdateResultJob.perform_later(@result, name: name)
      end
    end

    # Simulate expiration of semaphore and executions
    SolidQueue::Semaphore.where(key: job.concurrency_key).update_all(expires_at: 15.minutes.ago)
    SolidQueue::BlockedExecution.update_all(expires_at: 15.minutes.ago)

    # And wait for dispatcher to release the jobs
    wait_for_jobs_to_finish_for(5.seconds)
    assert_no_unfinished_jobs

    assert_stored_sequence @result, ("A".."K").to_a
  end

  test "don't block claimed executions that get released" do
    NonOverlappingUpdateResultJob.perform_later(@result, name: "I'll be released to ready", pause: SolidQueue.shutdown_timeout + 10.seconds)
    job = SolidQueue::Job.last

    wait_for(timeout: 2.seconds) { job.reload.claimed? }

    # This won't leave time to the job to finish, so the worker should
    # release it back to ready during shutdown.
    terminate_process(@pid)

    assert_not job.reload.finished?
    assert job.reload.ready?
  end

  test "verify transactions remain valid after Job creation conflicts via limits_concurrency" do
    # Doesn't work when enqueue_after_transaction_commit is enabled
    skip if ActiveJob::Base.respond_to?(:enqueue_after_transaction_commit) &&
            [ true, :default ].include?(ActiveJob::Base.enqueue_after_transaction_commit)

    ActiveRecord::Base.transaction do
      NonOverlappingUpdateResultJob.perform_later(@result, name: "A", pause: 0.2.seconds)
      NonOverlappingUpdateResultJob.perform_later(@result, name: "B")

      begin
        assert_equal 2, SolidQueue::Job.count
        assert true, "Transaction state valid"
      rescue ActiveRecord::StatementInvalid
        assert false, "Transaction state unexpectedly invalid"
      end
    end
  end

  test "discard jobs when concurrency limit is reached with on_conflict: :discard" do
    job1 = DiscardableUpdateResultJob.perform_later(@result, name: "1", pause: 1.second)
    wait_for(timeout: 2.seconds) { SolidQueue::Job.find_by(active_job_id: job1.job_id)&.claimed? }

    # should be discarded due to concurrency limit
    job2 = DiscardableUpdateResultJob.perform_later(@result, name: "2")
    # should also be discarded
    job3 = DiscardableUpdateResultJob.perform_later(@result, name: "3")

    wait_for_jobs_to_finish_for(5.seconds)
    assert_no_unfinished_jobs

    # Only the first job did something
    assert_stored_sequence(@result, [ "1" ])

    # All jobs have finished and have no blocked executions
    jobs = SolidQueue::Job.where(active_job_id: [ job1, job2, job3 ].map(&:job_id))
    assert_equal 1, jobs.count

    assert_equal job1.provider_job_id, jobs.first.id
    assert_nil job2.provider_job_id
    assert_nil job3.provider_job_id
  end

  test "discard on conflict across different concurrency keys" do
    another_result = JobResult.create!(queue_name: "default", status: "")
    DiscardableUpdateResultJob.perform_later(@result, name: "1", pause: 2)
    DiscardableUpdateResultJob.perform_later(another_result, name: "2", pause: 2)
    sleep(0.1)
    DiscardableUpdateResultJob.perform_later(@result, name: "3") # Should be discarded
    DiscardableUpdateResultJob.perform_later(another_result, name: "4") # Should be discarded

    wait_for_jobs_to_finish_for(5.seconds)
    assert_no_unfinished_jobs

    # Only the first 2 jobs did something
    assert_stored_sequence(@result, [ "1" ])
    assert_stored_sequence(another_result, [ "2" ])
  end

  test "discard on conflict and release semaphore" do
    DiscardableUpdateResultJob.perform_later(@result, name: "1", pause: 0.1)
    # will be discarded
    DiscardableUpdateResultJob.perform_later(@result, name: "2")

    wait_for_jobs_to_finish_for(5.seconds)
    wait_for_semaphores_to_be_released_for(2.seconds)

    assert_no_unfinished_jobs

    # Enqueue another job that shouldn't be discarded or blocked
    DiscardableUpdateResultJob.perform_later(@result, name: "3")
    wait_for_jobs_to_finish_for(5.seconds)
    assert_no_unfinished_jobs

    assert_stored_sequence(@result, [ "1", "3" ])
  end

  private
    def assert_stored_sequence(result, sequence)
      expected = sequence.sort.map { |name| "s#{name}c#{name}" }.join
      actual = skip_active_record_query_cache { result.reload.status.split(" + ").sort.join }
      assert_equal expected, actual
    end

    def wait_for_semaphores_to_be_released_for(timeout)
      wait_while_with_timeout(timeout) do
        skip_active_record_query_cache do
          SolidQueue::Semaphore.available.invert_where.any?
        end
      end
    end
end
