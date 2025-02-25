# frozen_string_literal: true

require "test_helper"

class LifecycleHooksTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "run lifecycle hooks" do
    SolidQueue.on_start do |s|
      name = s.class.name.demodulize.downcase
      JobResult.create!(status: :hook_called, value: "#{name}_start")
    end

    SolidQueue.on_stop do |s|
      name = s.class.name.demodulize.downcase
      JobResult.create!(status: :hook_called, value: "#{name}_stop")
    end

    SolidQueue.on_exit do |s|
      name = s.class.name.demodulize.downcase
      JobResult.create!(status: :hook_called, value: "#{name}_exit")
    end

    SolidQueue.on_worker_start do |w|
      name = w.class.name.demodulize.downcase
      queues = w.queues.join("_")
      JobResult.create!(status: :hook_called, value: "#{name}_#{queues}_start")
    end

    SolidQueue.on_worker_stop do |w|
      name = w.class.name.demodulize.downcase
      queues = w.queues.join("_")
      JobResult.create!(status: :hook_called, value: "#{name}_#{queues}_stop")
    end

    SolidQueue.on_worker_exit do |w|
      name = w.class.name.demodulize.downcase
      queues = w.queues.join("_")
      JobResult.create!(status: :hook_called, value: "#{name}_#{queues}_exit")
    end

    SolidQueue.on_dispatcher_start do |d|
      name = d.class.name.demodulize.downcase
      JobResult.create!(status: :hook_called, value: "#{name}_#{d.batch_size}_start")
    end

    SolidQueue.on_dispatcher_stop do |d|
      name = d.class.name.demodulize.downcase
      JobResult.create!(status: :hook_called, value: "#{name}_#{d.batch_size}_stop")
    end

    SolidQueue.on_dispatcher_exit do |d|
      name = d.class.name.demodulize.downcase
      JobResult.create!(status: :hook_called, value: "#{name}_#{d.batch_size}_exit")
    end

    SolidQueue.on_scheduler_start do |s|
      name = s.class.name.demodulize.downcase
      JobResult.create!(status: :hook_called, value: "#{name}_start")
    end

    SolidQueue.on_scheduler_stop do |s|
      name = s.class.name.demodulize.downcase
      JobResult.create!(status: :hook_called, value: "#{name}_stop")
    end

    SolidQueue.on_scheduler_exit do |s|
      name = s.class.name.demodulize.downcase
      JobResult.create!(status: :hook_called, value: "#{name}_exit")
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
      supervisor_start supervisor_stop supervisor_exit
      worker_first_queue_start worker_first_queue_stop worker_first_queue_exit
      worker_second_queue_start worker_second_queue_stop worker_second_queue_exit
      dispatcher_100_start dispatcher_100_stop dispatcher_100_exit
      scheduler_start scheduler_stop scheduler_exit
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
