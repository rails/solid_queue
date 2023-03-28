require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  test "read configuration from default file" do
    configuration = SolidQueue::Configuration.new
    assert 2, configuration.queues.count
    assert_not_empty configuration.scheduler_options
  end

  test "provide configuration as a hash and fill defaults" do
    configuration = SolidQueue::Configuration.new(queues: { background: { polling_interval: 10 } })
    assert_equal SolidQueue::Configuration::SCHEDULER_DEFAULTS, configuration.scheduler_options
    assert configuration.queues[:background][:pool_size] > 0
    assert_equal SolidQueue::Configuration::WORKER_DEFAULTS.merge(queue_name: "default"), configuration.queues[:default]
  end
end
