# frozen_string_literal: true

require "test_helper"

class ConcurrencyControlsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @result = JobResult.create!(queue_name: "default", status: "seq: ")

    default_worker = { queues: "default", polling_interval: 0.1, processes: 3, threads: 2 }
    dispatcher = { polling_interval: 0.1, batch_size: 200, concurrency_maintenance_interval: 1 }

    @pid = run_supervisor_as_fork(load_configuration_from: { workers: [ default_worker ], dispatchers: [ dispatcher ] })

    wait_for_registered_processes(5, timeout: 0.5.second) # 3 workers working the default queue + dispatcher + supervisor
  end

  teardown do
    terminate_process(@pid) if process_exists?(@pid)

    SolidQueue::Job.destroy_all
    SolidQueue::Process.destroy_all
    SolidQueue::Semaphore.delete_all
  end

  test "run several conflicting jobs over the same record sequentially" do
    ("A".."F").each do |name|
      SequentialUpdateResultJob.perform_later(@result, name: name, pause: 0.2.seconds)
    end

    ("G".."K").each do |name|
      SequentialUpdateResultJob.perform_later(@result, name: name)
    end

    wait_for_jobs_to_finish_for(3.seconds)
    assert_no_pending_jobs

    assert_stored_sequence @result, ("A".."K").to_a
  end

  test "schedule several conflicting jobs over the same record sequentially" do
    UpdateResultJob.set(wait: 0.2.seconds).perform_later(@result, name: "000", pause: 0.1.seconds)

    ("A".."F").each_with_index do |name, i|
      SequentialUpdateResultJob.set(wait: (0.2 + i * 0.01).seconds).perform_later(@result, name: name, pause: 0.3.seconds)
    end

    ("G".."K").each_with_index do |name, i|
      SequentialUpdateResultJob.set(wait: (0.3 + i * 0.01).seconds).perform_later(@result, name: name)
    end

    wait_for_jobs_to_finish_for(5.seconds)
    assert_no_pending_jobs

    assert_stored_sequence @result, ("A".."K").to_a
  end

  test "run several jobs over the same record limiting concurrency" do
    incr = 0
    # C is the last one to update the record
    # A: 0 to 0.5
    # B: 0 to 1.0
    # C: 0 to 1.5
    assert_no_difference -> { SolidQueue::BlockedExecution.count } do
      ("A".."C").each do |name|
        ThrottledUpdateResultJob.perform_later(@result, name: name, pause: (0.5 + incr).seconds)
        incr += 0.5
      end
    end

    sleep(0.01) # To ensure these aren't picked up before ABC
    # D to H: 0.51 to 0.76 (starting after A finishes, and in order, 5 * 0.05 = 0.25)
    # These would finish all before B and C
    assert_difference -> { SolidQueue::BlockedExecution.count }, +5 do
      ("D".."H").each do |name|
        ThrottledUpdateResultJob.perform_later(@result, name: name, pause: 0.05.seconds)
      end
    end

    wait_for_jobs_to_finish_for(3.seconds)
    assert_no_pending_jobs

    # C would have started in the beginning, seeing the status empty, and would finish after
    # all other jobs, so it'll do the last update with only itself
    assert_stored_sequence(@result, [ "C" ])
  end

  test "run several jobs over the same record sequentially, with some of them failing" do
    ("A".."F").each_with_index do |name, i|
      # A, C, E will fail, for i= 0, 2, 4
      SequentialUpdateResultJob.perform_later(@result, name: name, pause: 0.2.seconds, exception: (RuntimeError if i.even?))
    end

    ("G".."K").each do |name|
      SequentialUpdateResultJob.perform_later(@result, name: name)
    end

    wait_for_jobs_to_finish_for(3.seconds)
    assert_equal 3, SolidQueue::FailedExecution.count

    assert_stored_sequence @result, [ "B", "D", "F" ] + ("G".."K").to_a
  end

  test "rely on dispatcher to unblock blocked executions with an available semaphore" do
    # Simulate a scenario where we got an available semaphore and some stuck jobs
    job = SequentialUpdateResultJob.perform_later(@result, name: "A")

    wait_for_jobs_to_finish_for(3.seconds)
    assert_no_pending_jobs

    wait_while_with_timeout(1.second) { SolidQueue::Semaphore.where(value: 0).any? }
    # Lock the semaphore so we can enqueue jobs and leave them blocked
    skip_active_record_query_cache do
      assert SolidQueue::Semaphore.wait(job)
    end

    # Now enqueue more jobs under that same key. They'll be all locked
    assert_difference -> { SolidQueue::BlockedExecution.count }, +10 do
      ("B".."K").each do |name|
        SequentialUpdateResultJob.perform_later(@result, name: name)
      end
    end

    # Then unlock the semaphore and expire the jobs: this would be as if the first job had
    # released the semaphore but hadn't unblocked any jobs
    SolidQueue::BlockedExecution.update_all(expires_at: 15.minutes.ago)
    assert SolidQueue::Semaphore.signal(job)

    # And wait for the dispatcher to release the jobs
    wait_for_jobs_to_finish_for(3.seconds)
    assert_no_pending_jobs

    # We can't ensure the order between B and C, because it depends on which worker wins when
    # unblocking, as one will try to unblock B and another C
    assert_stored_sequence @result, ("A".."K").to_a, [ "A", "C", "B" ] + ("D".."K").to_a
  end

  test "rely on dispatcher to unblock blocked executions with an expired semaphore" do
    # Simulate a scenario where we got an available semaphore and some stuck jobs
    job = SequentialUpdateResultJob.perform_later(@result, name: "A")
    wait_for_jobs_to_finish_for(3.seconds)
    assert_no_pending_jobs

    wait_while_with_timeout(1.second) { SolidQueue::Semaphore.where(value: 0).any? }
    # Lock the semaphore so we can enqueue jobs and leave them blocked
    skip_active_record_query_cache do
      assert SolidQueue::Semaphore.wait(job)
    end

    # Now enqueue more jobs under that same key. They'll be all locked
    assert_difference -> { SolidQueue::BlockedExecution.count }, +10 do
      ("B".."K").each do |name|
        SequentialUpdateResultJob.perform_later(@result, name: name)
      end
    end

    # Simulate expiration of semaphore and executions
    SolidQueue::Semaphore.where(key: job.concurrency_key).update_all(expires_at: 15.minutes.ago)
    SolidQueue::BlockedExecution.update_all(expires_at: 15.minutes.ago)

    # And wait for dispatcher to release the jobs
    wait_for_jobs_to_finish_for(3.seconds)
    assert_no_pending_jobs

    # We can't ensure the order between B and C, because it depends on which worker wins when
    # unblocking, as one will try to unblock B and another C
    assert_stored_sequence @result, ("A".."K").to_a, [ "A", "C", "B" ] + ("D".."K").to_a
  end

  test "don't block claimed executions that get released" do
    SequentialUpdateResultJob.perform_later(@result, name: "I'll be released to ready", pause: SolidQueue.shutdown_timeout + 3.seconds)
    job = SolidQueue::Job.last

    sleep(0.2)
    assert job.claimed?

    # This won't leave time to the job to finish
    signal_process(@pid, :TERM, wait: 0.1.second)
    sleep(SolidQueue.shutdown_timeout + 0.2.seconds)

    assert_not job.reload.finished?
    assert job.reload.ready?
  end

  private
    def assert_stored_sequence(result, *sequences)
      expected = sequences.map { |sequence| "seq: " + sequence.map { |name| "s#{name}c#{name}" }.join }
      skip_active_record_query_cache do
        assert_includes expected, result.reload.status
      end
    end
end
