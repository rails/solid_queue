require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  test "read configuration from default file" do
    configuration = SolidQueue::Configuration.new(mode: :all)
    assert 3, configuration.runners.count
    assert_equal 2, configuration.workers.count
    assert configuration.scheduler.present?
  end

  test "provide configuration as a hash and fill defaults" do
    config_as_hash = { queues: { background: { polling_interval: 10 } } }
    configuration = SolidQueue::Configuration.new(mode: :all, load_from: config_as_hash)

    assert_equal SolidQueue::Configuration::SCHEDULER_DEFAULTS[:polling_interval], configuration.scheduler.polling_interval
    assert configuration.workers.detect { |w| w.queue == "background" }.pool_size > 0
  end

  test "max number of threads" do
    configuration = SolidQueue::Configuration.new(mode: :all)
    assert 7, configuration.max_number_of_threads
  end
end
