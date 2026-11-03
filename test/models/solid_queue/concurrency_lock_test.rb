# frozen_string_literal: true

require "test_helper"

class SolidQueue::ConcurrencyLockTest < ActiveSupport::TestCase
  class NonOverlappingJob < ActiveJob::Base
    limits_concurrency key: "concurrency-lock-test", duration: 1.minute

    def perform(name)
    end
  end

  setup do
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "worker-123")
  end

  # From the reproduction in https://github.com/rails/solid_queue/issues/827
  test "a job that outlived its lock does not release the lock a later job acquired" do
    a = claim(NonOverlappingJob.perform_later("A"))

    travel_to 2.minutes.from_now
    SolidQueue::Semaphore.expired.delete_all

    b = claim(NonOverlappingJob.perform_later("B"))
    c = job_for(NonOverlappingJob.perform_later("C"))
    assert c.blocked?

    a.perform

    assert b.job.reload.claimed?
    assert c.reload.blocked?
  end

  test "a job that outlived its lock does not leave the key over its limit" do
    a = claim(NonOverlappingJob.perform_later("A"))

    travel_to 2.minutes.from_now
    SolidQueue::Semaphore.expired.delete_all

    b = claim(NonOverlappingJob.perform_later("B"))
    c = job_for(NonOverlappingJob.perform_later("C"))
    d = job_for(NonOverlappingJob.perform_later("D"))

    a.perform
    b.perform
    claim_job(c)

    assert d.reload.blocked?
  end

  test "a job that got its slot gives it back even if its class is missing when it runs" do
    a = claim(NonOverlappingJob.perform_later("A"))
    b = job_for(NonOverlappingJob.perform_later("B"))
    assert b.blocked?

    # A worker on a release without the class claims and runs A
    a.job.update_column(:class_name, "RemovedJobClass")
    a = SolidQueue::ClaimedExecution.find(a.id)

    assert_raises(SolidQueue::Job::ClassMissingError) { a.perform }

    assert b.reload.ready?
    assert_equal 0, semaphore.value
  end

  test "a job that skipped its limits because its class was missing doesn't give back a slot" do
    a = claim(NonOverlappingJob.perform_later("A"))
    b = job_for(NonOverlappingJob.perform_later("B"))

    # Dispatched by a process without the class, so it takes no slot
    x = SolidQueue::Job.create!(queue_name: "default", class_name: "RemovedJobClass", active_job_id: SecureRandom.uuid,
      arguments: { "job_class" => "RemovedJobClass", "arguments" => [ "X" ] }, concurrency_key: a.job.concurrency_key)
    assert x.ready?

    # ...and run by one that has it
    x.update_columns(class_name: NonOverlappingJob.name, arguments: x.arguments.merge("job_class" => NonOverlappingJob.name))
    claim_job(x).perform

    assert a.job.reload.claimed?
    assert b.reload.blocked?
  end

  test "a job dispatched before Solid Queue recorded its semaphore gives back its slot by key" do
    a = claim(NonOverlappingJob.perform_later("A"))
    b = job_for(NonOverlappingJob.perform_later("B"))
    a.job.update_column(:arguments, a.job.arguments.except(SolidQueue::Job::ConcurrencyControls::CONCURRENCY_LOCK_KEY))
    a = SolidQueue::ClaimedExecution.find(a.id)

    a.perform

    assert b.reload.ready?
  end

  test "a blocked job records the semaphore it gets when it's released" do
    a = claim(NonOverlappingJob.perform_later("A"))
    b = job_for(NonOverlappingJob.perform_later("B"))
    assert a.job.concurrency_lock["semaphore_id"].present?
    assert_not b.concurrency_lock_recorded?

    a.perform

    assert b.reload.ready?
    assert_equal semaphore.id, b.concurrency_lock["semaphore_id"]
    assert_equal 1, b.concurrency_lock["limit"]
  end

  test "jobs enqueued in bulk record the semaphore they get" do
    ActiveJob.perform_all_later([ NonOverlappingJob.new("A"), NonOverlappingJob.new("B") ])
    a, b = SolidQueue::Job.where(class_name: NonOverlappingJob.name).order(:id).to_a

    assert a.ready?
    assert_equal semaphore.id, a.concurrency_lock["semaphore_id"]
    assert b.blocked?
    assert_not b.concurrency_lock_recorded?
  end

  private
    def semaphore
      SolidQueue::Semaphore.sole
    end

    def job_for(active_job)
      SolidQueue::Job.find_by!(active_job_id: active_job.job_id)
    end

    def claim(active_job)
      claim_job(job_for(active_job))
    end

    def claim_job(job)
      SolidQueue::ReadyExecution.claim(job.queue_name, 1, @process.id)
      SolidQueue::ClaimedExecution.find_by!(job_id: job.id)
    end
end
