require "test_helper"

class SolidQueue::ProcessTest < ActiveSupport::TestCase
  test "prune processes with expired heartbeats" do
    SolidQueue::Process.register({ pid: 42 })
    SolidQueue::Process.register({ pid: 24 })

    travel_to 10.minutes.from_now

    SolidQueue::Process.register({ pid: 16 })

    assert_difference -> { SolidQueue::Process.count }, -2 do
      SolidQueue::Process.prune
    end
  end
end
