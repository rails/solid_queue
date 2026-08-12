require "test_helper"

class BootGuardsTest < ActiveSupport::TestCase
  setup do
    @previous_fork_boot_timeout = SolidQueue.fork_boot_timeout
    SolidQueue.fork_boot_timeout = 0.1.seconds
  end

  teardown do
    SolidQueue.fork_boot_timeout = @previous_fork_boot_timeout
    @guard&.close
  end

  test "a fork guard times out when boot doesn't complete within the configured timeout" do
    @guard = SolidQueue::Processes::BootGuards::ForkGuard.new

    assert_not @guard.completed?
    assert_not @guard.timed_out?

    sleep SolidQueue.fork_boot_timeout

    assert_not @guard.completed?
    assert @guard.timed_out?
  end

  test "a fork guard completed from the forked process doesn't time out" do
    @guard = SolidQueue::Processes::BootGuards::ForkGuard.new

    pid = fork do
      @guard.complete
      exit!(0)
    end
    @guard.start
    Process.waitpid(pid)

    assert @guard.completed?

    sleep SolidQueue.fork_boot_timeout

    assert @guard.completed?
    assert_not @guard.timed_out?
  end

  test "a fork guard reads as completed when the forked process exits before finishing its boot" do
    @guard = SolidQueue::Processes::BootGuards::ForkGuard.new

    pid = fork { exit!(0) }
    @guard.start
    Process.waitpid(pid)

    # EOF on the pipe: the process will be replaced when it's reaped
    assert @guard.completed?
    assert_not @guard.timed_out?
  end

  test "a null guard completes on boot and never times out" do
    @guard = SolidQueue::Processes::BootGuards::NullGuard.new

    assert_not @guard.completed?
    assert_not @guard.timed_out?

    @guard.complete

    assert @guard.completed?
    assert_not @guard.timed_out?
  end
end
