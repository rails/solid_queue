require "test_helper"

class AsyncSupervisorTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "start as sidecar" do
    supervisor = run_supervisor_as_sidecar
    wait_for_registered_processes(4)

    assert_registered_processes(kind: "Supervisor(async)")
    assert_registered_processes(kind: "Worker", supervisor_id: supervisor.process_id, count: 2)
    assert_registered_processes(kind: "Dispatcher", supervisor_id: supervisor.process_id)

    supervisor.stop

    assert_no_registered_processes
  end

  test "start as separate process" do
    pid = run_supervisor_as_fork(mode: :async)
    wait_for_registered_processes(4)

    assert_registered_processes(kind: "Supervisor(async)")
    assert_registered_processes(kind: "Worker", supervisor_pid: pid, count: 2)
    assert_registered_processes(kind: "Dispatcher", supervisor_pid: pid)

    terminate_process(pid)
    assert_no_registered_processes
  end

  test "start as sidecar with provided configuration" do
    config_as_hash = { workers: [], dispatchers: [ { batch_size: 100 } ] }
    supervisor = run_supervisor_as_sidecar(load_configuration_from: config_as_hash)
    wait_for_registered_processes(2) # supervisor + dispatcher

    assert_registered_processes(kind: "Supervisor(async)")
    assert_registered_processes(kind: "Worker", count: 0)
    assert_registered_processes(kind: "Dispatcher", supervisor_id: supervisor.process_id)

    supervisor.stop

    assert_no_registered_processes
  end

  test "failed orphaned executions" do
    3.times { |i| StoreResultJob.set(queue: :new_queue).perform_later(i) }
    process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "worker-123")

    SolidQueue::ReadyExecution.claim("*", 5, process.id)

    assert_equal 3, SolidQueue::ClaimedExecution.count
    assert_equal 0, SolidQueue::ReadyExecution.count

    assert_equal [ process.id ], SolidQueue::ClaimedExecution.last(3).pluck(:process_id).uniq

    # Simnulate orphaned executions by just wiping the claiming process
    process.delete

    config_as_hash = {
      workers: [ { queues: "background", polling_interval: 10, processes: 2 } ],
      dispatchers: []
    }

    supervisor = run_supervisor_as_sidecar(load_configuration_from: config_as_hash)
    wait_for_registered_processes(3)
    assert_registered_processes(kind: "Supervisor(async)")

    supervisor.stop

    assert_equal 0, SolidQueue::ClaimedExecution.count
    assert_equal 3, SolidQueue::FailedExecution.count
  end

  private
    def run_supervisor_as_sidecar(**kwargs)
      SolidQueue::Supervisor.start(mode: :async, sidecar: true, **kwargs)
    end
end
