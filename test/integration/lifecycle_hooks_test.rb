# frozen_string_literal: true

require "test_helper"

class LifecycleHooksTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "run lifecycle hooks" do
    SolidQueue.on_start do |s|
      JobResult.create!(status: :hook_called, value: "#{s.class.name.demodulize}_start")
    end

    SolidQueue.on_stop do |s|
      JobResult.create!(status: :hook_called, value: "#{s.class.name.demodulize}_stop")
    end

    SolidQueue.on_exit do |s|
      JobResult.create!(status: :hook_called, value: "#{s.class.name.demodulize}_exit")
    end

    SolidQueue.on_worker_start do |w|
      JobResult.create!(status: :hook_called, value: "worker_#{w.queues.join}_start")
    end

    SolidQueue.on_worker_stop do |w|
      JobResult.create!(status: :hook_called, value: "worker_#{w.queues.join}_stop")
    end

    SolidQueue.on_worker_exit do |w|
      JobResult.create!(status: :hook_called, value: "worker_#{w.queues.join}_exit")
    end

    SolidQueue.on_dispatcher_start do |d|
      JobResult.create!(status: :hook_called, value: "dispatcher_#{d.batch_size}_start")
    end

    SolidQueue.on_dispatcher_stop do |d|
      JobResult.create!(status: :hook_called, value: "dispatcher_#{d.batch_size}_stop")
    end

    SolidQueue.on_dispatcher_exit do |d|
      JobResult.create!(status: :hook_called, value: "dispatcher_#{d.batch_size}_exit")
    end

    SolidQueue.on_scheduler_start do |s|
      JobResult.create!(status: :hook_called, value: "#{s.class.name.demodulize}_start")
    end

    SolidQueue.on_scheduler_stop do |s|
      JobResult.create!(status: :hook_called, value: "#{s.class.name.demodulize}_stop")
    end

    SolidQueue.on_scheduler_exit do |s|
      JobResult.create!(status: :hook_called, value: "#{s.class.name.demodulize}_exit")
    end

    pid = run_supervisor_as_fork(
      workers: [ { queues: "first_queue" }, { queues: "second_queue", processes: 1 } ],
      dispatchers: [ { batch_size: 100 } ],
      skip_recurring: false
    )

    wait_for_registered_processes(5)

    terminate_process(pid)
    wait_for_registered_processes(0)


    results = skip_active_record_query_cache do
      job_results = JobResult.where(status: :hook_called)
      assert_equal 15, job_results.count
      job_results
    end

    assert_equal({ "hook_called" => 15 }, results.map(&:status).tally)
    assert_equal %w[
      Supervisor_start Supervisor_stop Supervisor_exit
      worker_first_queue_start worker_first_queue_stop worker_first_queue_exit
      worker_second_queue_start worker_second_queue_stop worker_second_queue_exit
      dispatcher_100_start dispatcher_100_stop dispatcher_100_exit
      Scheduler_start Scheduler_stop Scheduler_exit
    ].sort, results.map(&:value).sort
  ensure
    SolidQueue::Supervisor.clear_hooks
    SolidQueue::Worker.clear_hooks
    SolidQueue::Dispatcher.clear_hooks
    SolidQueue::Scheduler.clear_hooks
  end

  test "handle errors on lifecycle hooks" do
    previous_on_thread_error, SolidQueue.on_thread_error = SolidQueue.on_thread_error, ->(error) { JobResult.create!(status: :error, value: error.message) }
    SolidQueue.on_start { raise RuntimeError, "everything is broken" }

    pid = run_supervisor_as_fork
    wait_for_registered_processes(4)

    terminate_process(pid)
    wait_for_registered_processes(0)

    result = skip_active_record_query_cache { JobResult.last }

    assert_equal "error", result.status
    assert_equal "everything is broken", result.value
  ensure
    SolidQueue.on_thread_error = previous_on_thread_error
    SolidQueue::Supervisor.clear_hooks
    SolidQueue::Worker.clear_hooks
    SolidQueue::Dispatcher.clear_hooks
    SolidQueue::Scheduler.clear_hooks
  end
end
