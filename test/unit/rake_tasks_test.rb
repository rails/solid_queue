# frozen_string_literal: true

require "test_helper"
require "rake"

class RakeTasksTest < ActiveSupport::TestCase
  setup do
    @previous_rake_application = Rake.application
    @rake = Rake::Application.new
    Rake.application = @rake
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/solid_queue/tasks.rb", __dir__)
  end

  teardown do
    Rake.application = @previous_rake_application
  end

  test "solid_queue:check exits 0 and prints OK message for a valid configuration" do
    SolidQueue::Configuration.any_instance.stubs(:skip_recurring_tasks?).returns(true)

    out, err = capture_io do
      assert_nothing_raised { @rake["solid_queue:check"].invoke }
    end

    assert_match "Solid Queue configuration is valid.", out
    assert_empty err
  end

  test "solid_queue:check exits 1 and prints errors for an invalid configuration" do
    SolidQueue::Configuration.any_instance.stubs(:invalid_tasks).returns(
      [ stub(key: "broken", errors: stub(full_messages: [ "is invalid" ])) ]
    )
    SolidQueue::Configuration.any_instance.stubs(:skip_recurring_tasks?).returns(false)

    status = nil
    out, err = capture_io do
      begin
        @rake["solid_queue:check"].invoke
      rescue SystemExit => e
        status = e.status
      end
    end

    assert_equal 1, status
    assert_empty out
    assert_match "Solid Queue configuration is invalid:", err
    assert_match "broken", err
  end
end
