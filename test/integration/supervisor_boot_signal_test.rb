# frozen_string_literal: true

require "test_helper"

class SupervisorBootSignalTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @marker_path = Rails.root.join("tmp/solid_queue_start_hook_#{SecureRandom.hex(8)}")
    @release_path = Rails.root.join("tmp/solid_queue_release_start_hook_#{SecureRandom.hex(8)}")
  end

  teardown do
    File.delete(@marker_path) if File.exist?(@marker_path)
    File.delete(@release_path) if File.exist?(@release_path)
  end

  # Regression for https://github.com/rails/solid_queue/issues/755:
  # TERM received while the supervisor is still running start hooks used to sit
  # in the signal queue until after workers were forked. Those workers then
  # inherited the supervisor's enqueue-only trap and kept claiming jobs until
  # SIGKILL.
  test "TERM during supervisor start hooks exits without starting workers" do
    resetting_hooks do
      marker_path = @marker_path
      release_path = @release_path

      SolidQueue.on_start do
        File.write(marker_path, Process.pid.to_s)
        Timeout.timeout(5) { sleep 0.05 until File.exist?(release_path) }
      end

      SolidQueue.on_worker_start do
        JobResult.create!(queue_name: "background", status: "hook_called", value: "worker_started")
      end

      3.times { |i| StoreResultJob.set(queue: :background).perform_later("should_not_run_#{i}") }

      pid = run_supervisor_as_fork(
        workers: [ { queues: :background, threads: 1, polling_interval: 0.1 } ],
        dispatchers: []
      )

      wait_while_with_timeout!(5.seconds) { !File.exist?(marker_path) }
      Process.kill(:TERM, pid)
      File.write(release_path, "1")

      wait_for_process_termination_with_timeout(pid, timeout: SolidQueue.shutdown_timeout + 5.seconds)

      skip_active_record_query_cache do
        assert_equal 0, JobResult.where(value: "worker_started").count
        assert_equal 0, JobResult.where(status: "completed").count
        assert_equal 0, SolidQueue::ClaimedExecution.count
        assert_equal 3, SolidQueue::ReadyExecution.count
        assert SolidQueue::Process.none?
      end
    end
  end

  private
    def resetting_hooks
      reset_hooks(SolidQueue::Supervisor) do
        reset_hooks(SolidQueue::Worker) do
          yield
        end
      end
    end

    def reset_hooks(process)
      exit_hooks = process.lifecycle_hooks[:exit]
      start_hooks = process.lifecycle_hooks[:start]
      stop_hooks = process.lifecycle_hooks[:stop]
      process.lifecycle_hooks[:exit] = []
      process.lifecycle_hooks[:start] = []
      process.lifecycle_hooks[:stop] = []
      yield
    ensure
      process.lifecycle_hooks[:exit] = exit_hooks
      process.lifecycle_hooks[:start] = start_hooks
      process.lifecycle_hooks[:stop] = stop_hooks
    end
end
