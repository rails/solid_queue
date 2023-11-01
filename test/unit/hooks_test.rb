require "test_helper"

class HooksTest < ActiveSupport::TestCase
  test "solid_queue_record hook ran" do
    assert Rails.application.config.x.solid_queue_record_hook_ran
  end
end
