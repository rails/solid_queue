require "test_helper"

class SolidQueueTest < ActiveSupport::TestCase
  test "it has a version number" do
    assert SolidQueue::VERSION
  end

  test "creates recurring tasks" do
    SolidQueue.create_recurring_task("test 1", command: "puts 1", schedule: "every hour")
    SolidQueue.create_recurring_task("test 2", command: "puts 2", schedule: "every minute", static: true)

    assert SolidQueue::RecurringTask.exists?(key: "test 1", command: "puts 1", schedule: "every hour", static: false)
    assert SolidQueue::RecurringTask.exists?(key: "test 2", command: "puts 2", schedule: "every minute", static: false)
  end

  test "destroys recurring tasks" do
    dynamic_task = SolidQueue::RecurringTask.create!(
      key: "dynamic", command: "puts 'd'", schedule: "every day", static: false
    )

    static_task = SolidQueue::RecurringTask.create!(
      key: "static", command: "puts 's'", schedule: "every week", static: true
    )

    SolidQueue.destroy_recurring_task(dynamic_task.id)

    assert_raises(ActiveRecord::RecordNotFound) do
      SolidQueue.destroy_recurring_task(static_task.id)
    end

    assert_not SolidQueue::RecurringTask.exists?(key: "dynamic", static: false)
    assert SolidQueue::RecurringTask.exists?(key: "static", static: true)
  end
end
