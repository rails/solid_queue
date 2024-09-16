# frozen_string_literal: true

require "test_helper"

class InstrumentationTest < ActiveSupport::TestCase
  test "dispatcher polling emits dispatch_scheduled event" do
    8.times { AddToBufferJob.set(wait: 1.day).perform_later("I'm scheduled") }

    events = subscribed("dispatch_scheduled.solid_queue") do
      travel_to 2.days.from_now
      dispatcher = SolidQueue::Dispatcher.new(polling_interval: 0.1, batch_size: 10).tap(&:start)

      wait_while_with_timeout!(0.5.seconds) { SolidQueue::ScheduledExecution.any? }
      dispatcher.stop
    end

    assert_equal 1, events.size
    assert_event events.first, "dispatch_scheduled", batch_size: 10, size: 8
  end

  test "claiming jobs emits claim events" do
    3.times { StoreResultJob.perform_later(42) }
    process = nil
    jobs = SolidQueue::Job.last(3)

    events = subscribed("claim.solid_queue") do
      worker = SolidQueue::Worker.new.tap(&:start)

      wait_while_with_timeout!(3.seconds) { SolidQueue::ReadyExecution.any? }
      process = SolidQueue::Process.last

      worker.stop
      wait_for_registered_processes(0, timeout: 3.second)
    end

    assert_equal 1, events.size
    assert_event events.first, "claim", process_id: process.id, job_ids: jobs.map(&:id), claimed_job_ids: jobs.map(&:id), size: 3
  end

  test "polling emits events" do
    3.times { StoreResultJob.perform_later(42) }

    events = subscribed("polling.solid_queue") do
      worker = SolidQueue::Worker.new.tap(&:start)

      wait_while_with_timeout!(3.seconds) { SolidQueue::ReadyExecution.any? }

      worker.stop
    end

    assert events.size >= 4
    events.each { |e| assert_event e, "polling" }
  end

  test "stopping a worker with claimed executions emits release_claimed events" do
    StoreResultJob.perform_later(42, pause: SolidQueue.shutdown_timeout + 100.second)
    process = nil

    events = subscribed(/release.*_claimed\.solid_queue/) do
      worker = SolidQueue::Worker.new.tap(&:start)

      wait_while_with_timeout!(3.seconds) { SolidQueue::ReadyExecution.any? }
      process = SolidQueue::Process.last

      worker.stop
      wait_for_registered_processes(0, timeout: 3.second)
    end

    assert_equal 2, events.size
    release_one_event, release_many_event = events
    assert_event release_one_event, "release_claimed", job_id: SolidQueue::Job.last.id, process_id: process.id
    assert_event release_many_event, "release_many_claimed", size: 1
  end

  test "starting a runnable process emits a start_process event" do
    worker = SolidQueue::Worker.new

    events = subscribed("start_process.solid_queue") do
      worker.start
      wait_for_registered_processes(1, timeout: 1.second)

      worker.stop
      wait_for_registered_processes(0, timeout: 1.second)
    end

    assert_equal 1, events.size
    assert_event events.first, "start_process", process: worker
  end

  test "starting and stopping a worker emits register_process and deregister_process events" do
    StoreResultJob.perform_later(42, pause: SolidQueue.shutdown_timeout + 100.second)
    process = nil

    events = subscribed(/(register|deregister)_process\.solid_queue/) do
      worker = SolidQueue::Worker.new.tap(&:start)
      wait_while_with_timeout!(3.seconds) { SolidQueue::ReadyExecution.any? }

      process = SolidQueue::Process.last

      worker.stop
      wait_for_registered_processes(0, timeout: 3.second)
    end

    assert_equal 2, events.size
    register_event, deregister_event = events
    assert_event register_event, "register_process", kind: "Worker", pid: ::Process.pid, process_id: process.id
    assert_event deregister_event, "deregister_process", process: process, pruned: false
  end

  test "starting and stopping a dispatcher emits register_process and deregister_process events" do
    process = nil

    events = subscribed(/(register|deregister)_process\.solid_queue/) do
      dispatcher = SolidQueue::Dispatcher.new.tap(&:start)
      wait_for_registered_processes(1, timeout: 3.second)

      process = SolidQueue::Process.last

      dispatcher.stop
      wait_for_registered_processes(0, timeout: 3.second)
    end

    assert_equal 2, events.size
    register_event, deregister_event = events
    assert_event register_event, "register_process", kind: "Dispatcher", pid: ::Process.pid, process_id: process.id
    assert_event deregister_event, "deregister_process", process: process, pruned: false
  end

  test "pruning processes emit prune_processes and deregister_process events" do
    processes = 3.times.collect { |i| SolidQueue::Process.create!(kind: "Worker", supervisor_id: 42, pid: 10 + i, hostname: "localhost", last_heartbeat_at: 3.days.ago, name: "worker-123#{i}") }

    events = subscribed(/.*process.*\.solid_queue/) do
      SolidQueue::Process.prune
    end

    # 1 prune event + 3 deregister events
    assert_equal 4, events.count
    deregister_events = events.first(3)
    prune_event = events.last

    assert_event prune_event, "prune_processes", size: 3
    deregister_events.each_with_index do |event, i|
      assert_event event, "deregister_process", process: processes[i], pruned: true
    end
  end

  test "pruning a process with claimed executions emits fail_many_claimed event" do
    process = SolidQueue::Process.create!(kind: "Worker", supervisor_id: 42, pid: 10, last_heartbeat_at: 3.days.ago, name: "worker-123")

    3.times { |i| StoreResultJob.set(queue: :new_queue).perform_later(i) }
    jobs = SolidQueue::Job.last(3)

    SolidQueue::ReadyExecution.claim("*", 5, process.id)

    events = subscribed(/fail.*_claimed\.solid_queue/) do
      SolidQueue::Process.prune
    end

    assert_equal 1, events.count
    assert_event events.first, "fail_many_claimed", process_ids: [ process.id ], job_ids: jobs.map(&:id), size: 3
  end

  test "errors when deregistering processes are included in deregister_process events" do
    previous_thread_report_on_exception, Thread.report_on_exception = Thread.report_on_exception, false
    error = RuntimeError.new("everything is broken")
    SolidQueue::Process.any_instance.expects(:destroy!).raises(error).at_least_once

    events = subscribed("deregister_process.solid_queue") do
      assert_raises RuntimeError do
        worker = SolidQueue::Worker.new.tap(&:start)
        wait_for_registered_processes(1, timeout: 1.second)

        worker.stop
        wait_for_registered_processes(0, timeout: 1.second)
      end
    end

    assert_equal 1, events.size
    assert_event events.first, "deregister_process", error: error
  ensure
    Thread.report_on_exception = previous_thread_report_on_exception
  end

  test "retrying failed job emits retry event" do
    RaisingJob.perform_later(RuntimeError, "A")
    job = SolidQueue::Job.last

    worker = SolidQueue::Worker.new.tap(&:start)
    wait_for_jobs_to_finish_for(3.seconds)
    worker.stop

    events = subscribed("retry.solid_queue") do
      job.reload.retry
    end

    assert_equal 1, events.size
    assert_event events.first, "retry", job_id: job.id
  end

  test "retrying failed jobs in bulk emits retry_all" do
    3.times { RaisingJob.perform_later(RuntimeError, "A") }
    AddToBufferJob.perform_later("A")

    jobs = SolidQueue::Job.last(4)

    worker = SolidQueue::Worker.new.tap(&:start)
    wait_for_jobs_to_finish_for(3.seconds)
    worker.stop

    events = subscribed("retry_all.solid_queue") do
      SolidQueue::FailedExecution.retry_all(jobs)
      SolidQueue::FailedExecution.retry_all(jobs)
    end

    assert_equal 2, events.size
    assert_event events.first, "retry_all", jobs_size: 4, size: 3
    assert_event events.second, "retry_all", jobs_size: 4, size: 0
  end

  test "discarding job emits a discard event" do
    AddToBufferJob.perform_later("A")
    job = SolidQueue::Job.last

    events = subscribed("discard.solid_queue") do
      job.discard
    end

    assert_equal 1, events.size
    assert_event events.first, "discard", job_id: job.id, status: :ready
  end

  test "discarding jobs in bulk emits a discard_all event" do
    # 5 ready jobs
    5.times { AddToBufferJob.perform_later("A") }
    # 1 ready + 3 blocked
    result = JobResult.create!
    4.times { SequentialUpdateResultJob.perform_later(result, name: "A") }

    events = subscribed("discard_all.solid_queue") do
      SolidQueue::ReadyExecution.discard_all_from_jobs(SolidQueue::Job.all)
      SolidQueue::ReadyExecution.discard_all_from_jobs(SolidQueue::Job.all)
    end

    assert_equal 2, events.size
    assert_event events.first, "discard_all", jobs_size: 9, status: :ready, size: 6
    # Only 3 blocked jobs remaining for the second discard_all_from_jobs call
    assert_event events.second, "discard_all", jobs_size: 3, status: :ready, size: 0
  end

  test "discarding jobs in batches emits a discard_all event" do
    15.times { AddToBufferJob.perform_later("A") }

    events = subscribed("discard_all.solid_queue") do
      SolidQueue::ReadyExecution.discard_all_in_batches(batch_size: 6)
    end

    assert_equal 1, events.size
    assert_event events.first, "discard_all", batch_size: 6, status: :ready, batches: 3, size: 15
  end

  test "unblocking job emits release_blocked event" do
    result = JobResult.create!
    # 1 ready, 2 blocked
    3.times { SequentialUpdateResultJob.perform_later(result, name: "A") }

    # Simulate expiry of the concurrency locks
    travel_to 3.days.from_now
    SolidQueue::Semaphore.expired.delete_all

    blocked_jobs = SolidQueue::BlockedExecution.last(2).map(&:job)
    concurrency_key = blocked_jobs.first.concurrency_key

    events = subscribed("release_blocked.solid_queue") do
      SolidQueue::BlockedExecution.release_one(concurrency_key)
      SolidQueue::BlockedExecution.release_one(concurrency_key)
    end

    assert_equal 2, events.size
    assert_event events.first, "release_blocked", job_id: blocked_jobs.first.id, concurrency_key: concurrency_key, released: true
    assert_event events.second, "release_blocked", job_id: blocked_jobs.second.id, concurrency_key: concurrency_key, released: false
  end

  test "unblocking jobs in bulk emits release_many_blocked event" do
    result = JobResult.create!
    # 1 ready, 3 blocked
    4.times { SequentialUpdateResultJob.perform_later(result, name: "A") }

    # 1 ready, 2 blocked
    result = JobResult.create!
    3.times { SequentialUpdateResultJob.perform_later(result, name: "B") }

    # Simulate expiry of the concurrency locks
    travel_to 3.days.from_now
    SolidQueue::Semaphore.expired.delete_all

    events = subscribed("release_many_blocked.solid_queue") do
      SolidQueue::BlockedExecution.unblock(5)
      SolidQueue::BlockedExecution.unblock(5)
    end

    assert_equal 2, events.size
    assert_event events.first, "release_many_blocked", limit: 5, size: 2
    assert_event events.second, "release_many_blocked", limit: 5, size: 0
  end

  test "enqueuing recurring task emits enqueue_recurring_task event" do
    recurring_task = { example_task: { class: "AddToBufferJob", schedule: "every second", args: 42 } }
    scheduler = SolidQueue::Scheduler.new(recurring_tasks: recurring_task)

    events = subscribed("enqueue_recurring_task.solid_queue") do
      scheduler.start
      sleep 1.01
      scheduler.stop
    end

    assert events.size >= 1
    event = events.last

    assert_event event, "enqueue_recurring_task", task: "example_task", active_job_id: SolidQueue::Job.last.active_job_id
    assert event.last[:at].present?
    assert_nil event.last[:other_adapter]
  end

  test "skipping a recurring task is reflected in the enqueue_recurring_task event" do
    recurring_task = { example_task: { class: "AddToBufferJob", schedule: "every second", args: 42 } }
    schedulers = 2.times.collect { SolidQueue::Scheduler.new(recurring_tasks: recurring_task) }

    events = subscribed("enqueue_recurring_task.solid_queue") do
      schedulers.each(&:start)
      sleep 1.01
      schedulers.each(&:stop)
    end

    assert events.size >= 2
    events.each do |event|
      assert_event event, "enqueue_recurring_task", task: "example_task"
    end

    active_job_ids = SolidQueue::Job.all.map(&:active_job_id)
    events.group_by { |event| event.last[:at] }.each do |_, events_by_time|
      if events_by_time.many?
        assert events_by_time.any? { |e| e.last[:active_job_id].nil? }
        assert events_by_time.any? { |e| e.last[:active_job_id].in? active_job_ids }
      end
    end
  end

  test "an error enqueuing a recurring task in Solid Queue is reflected in the enqueue_recurring_task event" do
    recurring_task = { example_task: { class: "AddToBufferJob", schedule: "every second", args: 42 } }
    SolidQueue::Job.stubs(:create!).raises(ActiveRecord::Deadlocked)

    scheduler = SolidQueue::Scheduler.new(recurring_tasks: recurring_task)

    events = subscribed("enqueue_recurring_task.solid_queue") do
      scheduler.start
      sleep(1.01)
      scheduler.stop
    end

    assert events.size >= 1
    event = events.last

    assert_event event, "enqueue_recurring_task", task: "example_task", enqueue_error: "ActiveRecord::Deadlocked: ActiveRecord::Deadlocked"
    assert event.last[:at].present?
    assert_nil event.last[:other_adapter]
  end

  test "an error enqueuing a recurring task with another adapter is reflected in the enqueue_recurring_task event" do
    AddToBufferJob.queue_adapter = :async
    ActiveJob::QueueAdapters::AsyncAdapter.any_instance.stubs(:enqueue).raises(ActiveJob::EnqueueError.new("All is broken"))

    recurring_task = { example_task: { class: "AddToBufferJob", schedule: "every second", args: 42 } }

    scheduler = SolidQueue::Scheduler.new(recurring_tasks: recurring_task)

    events = subscribed("enqueue_recurring_task.solid_queue") do
      scheduler.start
      sleep(1.01)
      scheduler.stop
    end

    assert events.size >= 1
    event = events.last

    assert_event event, "enqueue_recurring_task", task: "example_task", enqueue_error: "All is broken"
    assert event.last[:at].present?
    assert event.last[:other_adapter]
  ensure
    AddToBufferJob.queue_adapter = :solid_queue
  end

  test "thread errors emit thread_error events" do
    previous_thread_report_on_exception, Thread.report_on_exception = Thread.report_on_exception, false

    error = RuntimeError.new("everything is broken")
    SolidQueue::ClaimedExecution::Result.expects(:new).raises(error).at_least_once

    AddToBufferJob.perform_later "hey!"

    events = subscribed("thread_error.solid_queue") do
      SolidQueue::Worker.new.tap do |worker|
        worker.mode = :inline
        worker.start
      end
    end

    assert_equal 1, events.count
    assert_event events.first, "thread_error", error: error
  ensure
    Thread.report_on_exception = previous_thread_report_on_exception
  end

  private
    def subscribed(name, &block)
      [].tap do |events|
        ActiveSupport::Notifications.subscribed(->(*args) { events << args }, name, &block)
      end
    end

    def assert_event(event, action, **attributes)
      assert_equal "#{action}.solid_queue", event.first
      assert_equal attributes, event.last.slice(*attributes.keys)
    end
end
