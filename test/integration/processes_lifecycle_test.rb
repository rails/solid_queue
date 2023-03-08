# frozen_string_literal: true

require "test_helper"

class ProcessLifecycleTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @pid = run_supervisor_as_fork

    wait_for_registered_processes_for(1.second)
    assert_registered_processes_for(:background, :default)
  end

  teardown do
    terminate_supervisor if process_exists?(@pid)
  end

  test "enqueue jobs in multiple queues" do
    6.times.map { |i| enqueue_store_result_job("job_#{i}") }
    6.times.map { |i| enqueue_store_result_job("job_#{i}", :default) }

    wait_for_jobs_to_finish_for(5.seconds)

    assert_equal 12, JobResult.count
    6.times { |i| assert_completed_job_results("job_#{i}", :background) }
    6.times { |i| assert_completed_job_results("job_#{i}", :default) }

    terminate_supervisor
    assert_clean_termination
  end

  test "kill supervisor while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: 2.seconds)

    signal_fork(@pid, :KILL, wait: 1.second)
    wait_for_jobs_to_finish_for(5.seconds)

    assert_completed_job_results("no pause")
    assert_started_job_result("pause")

    assert_job_status(no_pause, :finished)
    assert_job_status(pause, :claimed)

    # Processes couldn't clean up after being killed
    assert_registered_processes_for(:background, :default)

    travel_to 10.minutes.from_now
    @pid = run_supervisor_as_fork

    wait_for_jobs_to_finish_for(5.seconds)

    assert_completed_job_results("pause")
    assert_job_status(pause, :finished)

    terminate_supervisor
    assert_clean_termination
  end

  test "quit supervisor while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: 2.seconds)

    signal_fork(@pid, :QUIT, wait: 1.second)
    wait_for_jobs_to_finish_for(5.seconds)

    assert_completed_job_results("no pause")
    assert_started_job_result("pause")

    assert_job_status(no_pause, :finished)
    assert_job_status(pause, :claimed)

    # Processes couldn't clean up after being killed
    assert_registered_processes_for(:background, :default)

    travel_to 10.minutes.from_now
    @pid = run_supervisor_as_fork

    wait_for_jobs_to_finish_for(5.seconds)

    assert_completed_job_results("pause")
    assert_job_status(pause, :finished)

    terminate_supervisor
    assert_clean_termination
  end

  test "term supervisor while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: 2.seconds)

    signal_fork(@pid, :TERM, wait: 1.second)
    wait_for_jobs_to_finish_for(5.seconds)

    assert_completed_job_results("no pause")
    assert_completed_job_results("pause")

    assert_job_status(no_pause, :finished)
    assert_job_status(pause, :finished)

    assert_clean_termination
  end

  test "int supervisor while there are jobs in-flight" do
    no_pause = enqueue_store_result_job("no pause")
    pause = enqueue_store_result_job("pause", pause: 2.seconds)

    signal_fork(@pid, :INT, wait: 1.second)
    wait_for_jobs_to_finish_for(5.seconds)

    assert_completed_job_results("no pause")
    assert_completed_job_results("pause")

    assert_job_status(no_pause, :finished)
    assert_job_status(pause, :finished)

    assert_clean_termination
  end

  test "process some jobs that raise errors" do
    enqueue_store_result_job("no error", :background, 2)
    enqueue_store_result_job("no error", :default, 2)
    error1 = enqueue_store_result_job("error", :background, 1, exception: RuntimeError)
    enqueue_store_result_job("no error", :background, 1, pause: 0.3)
    error2 = enqueue_store_result_job("error", :background, 1, exception: RuntimeError, pause: 0.5)
    enqueue_store_result_job("no error", :default, 2, pause: 0.1)
    error3 = enqueue_store_result_job("error", :default, 1, exception: RuntimeError)

    wait_for_jobs_to_finish_for(5.seconds)

    assert_completed_job_results("no error", :background, 3)
    assert_completed_job_results("no error", :default, 4)

    assert_failures 3
    [ error1, error2, error3 ].each do |job|
      assert_job_status(job, :failed)
    end

    terminate_supervisor
    assert_clean_termination
  end

  test "process a job that exits" do
    enqueue_store_result_job("no exit", :background, 2)
    enqueue_store_result_job("no exit", :default, 2)
    paused = enqueue_store_result_job("paused no exit", :default, 1, pause: 0.5)
    exit1 = enqueue_store_result_job("exit", :background, 1, exit: true, pause: 0.2)
    exit2 = enqueue_store_result_job("exit", :background, 1, exit: true, pause: 0.3)
    enqueue_store_result_job("no exit", :background, 2)

    wait_for_jobs_to_finish_for(5.seconds)

    assert_completed_job_results("no exit", :default, 2)
    [ paused, exit1, exit2 ].each do |job|
      assert_job_status(job, :claimed)
    end

    travel_to 10.minutes.from_now
    @pid = run_supervisor_as_fork

    wait_for_jobs_to_finish_for(5.seconds)

    # Paused job can't finish because the other will call exit before it gets a chance
    # to be run
    [ paused, exit1, exit2 ].each do |job|
      assert_job_status(job, :claimed)
    end

    assert_not process_exists?(@pid)
    assert_registered_processes_for(:default, :background)
  end

  private
    def run_supervisor_as_fork
      fork do
        SolidQueue::Supervisor.start
      end
    end

    def terminate_supervisor
      signal_fork(@pid, :TERM)
      wait_for_fork_with_timeout(@pid)
    end

    def assert_clean_termination
      assert_no_registered_processes
      assert_no_claimed_jobs
    end

    def wait_for_fork_with_timeout(pid)
      Timeout.timeout(10) do
        Process.waitpid(pid)
        assert 0, $?.exitstatus
      end
    rescue Timeout::Error
      Process.kill(:KILL, pid)
      raise
    end

    def signal_fork(pid, signal, wait: nil)
      Thread.new do
        sleep(wait) if wait
        Process.kill(signal, pid)
      end
    end

    def process_exists?(pid)
      Process.getpgid(pid)
      true
    rescue Errno::ESRCH
      false
    end

    def wait_for_registered_processes_for(timeout = 10.seconds)
      Timeout.timeout(timeout) do
        while SolidQueue::Process.none? do
          sleep 0.25
        end
      end
    rescue Timeout::Error
    end

    def assert_registered_processes_for(*queues)
      registered_queues = SolidQueue::Process.all.map { |process| process.metadata["queue"] }

      assert_equal queues.map(&:to_s).sort, registered_queues.sort
    end

    def assert_no_registered_processes
      assert SolidQueue::Process.none?
    end

    def enqueue_store_result_job(value, queue_name = :background, count = 1, **options)
      count.times.collect { StoreResultJob.set(queue: queue_name).perform_later(value, **options) }.then do |jobs|
        jobs.one? ? jobs.first : jobs
      end
    end

    def assert_completed_job_results(value, queue_name = :background, count = 1)
      assert_equal count, JobResult.where(queue_name: queue_name, status: "completed", value: value).count
    end

    def assert_started_job_result(value, queue_name = :background, count = 1)
      assert_equal count, JobResult.where(queue_name: queue_name, status: "started", value: value).count
    end

    def assert_job_status(active_job, status)
      # Make sure we skip AR query cache. Otherwise the queries done here
      # might be cached and since we haven't done any non-SELECT queries
      # after they were cached on the connection used in the test, the cache
      # will still apply, even though the data returned by the cached queries
      # might have been deleted in the forked processes.
      SolidQueue::Job.connection.uncached do
        job = SolidQueue::Job.find_by(active_job_id: active_job.job_id)
        assert job.public_send("#{status}?")
      end
    end

    def assert_no_claimed_jobs
      assert SolidQueue::ClaimedExecution.none?
    end

    def assert_failures(count)
      assert_equal count, SolidQueue::FailedExecution.count
    end
end
