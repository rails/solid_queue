module ProcessesTestHelper
  private

  def run_supervisor_as_fork(**options)
    fork do
      SolidQueue::Supervisor.start(**options.with_defaults(mode: :fork))
    end
  end

  def wait_for_registered_processes(count, timeout: 1.second)
    wait_while_with_timeout(timeout) { SolidQueue::Process.count != count }
  end

  def assert_no_registered_processes
    skip_active_record_query_cache do
      assert SolidQueue::Process.none?
    end
  end

  def assert_registered_processes(kind:, count: 1, supervisor_pid: nil, **attributes)
    processes = skip_active_record_query_cache { SolidQueue::Process.where(kind: kind).to_a }
    assert_equal count, processes.count

    if supervisor_pid
      processes.each do |process|
        assert_equal supervisor_pid, process.supervisor.pid
      end
    end

    attributes.each do |attr, value|
      processes.each do |process|
        if value.present?
          assert_equal value, process.public_send(attr)
        else
          assert_nil process.public_send(attr)
        end
      end
    end
  end

  def find_processes_registered_as(kind)
    skip_active_record_query_cache do
      SolidQueue::Process.where(kind: kind)
    end
  end

  def terminate_process(pid, timeout: 10, signal: :TERM)
    signal_process(pid, signal)
    wait_for_process_termination_with_timeout(pid, timeout: timeout)
  end

  def wait_for_process_termination_with_timeout(pid, timeout: 10, exitstatus: 0)
    Timeout.timeout(timeout) do
      if process_exists?(pid)
        Process.waitpid(pid)
        assert exitstatus, $?.exitstatus
      end
    end
  rescue Timeout::Error
    signal_process(pid, :KILL)
    raise
  end

  def signal_process(pid, signal, wait: nil)
    Thread.new do
      sleep(wait) if wait
      Process.kill(signal, pid)
    end
  end

  def process_exists?(pid)
    reap_processes
    Process.getpgid(pid)
    true
  rescue Errno::ESRCH
    false
  end

  def reap_processes
    Process.waitpid(-1, Process::WNOHANG)
  rescue Errno::ECHILD
  end
end
