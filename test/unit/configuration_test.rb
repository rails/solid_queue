require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  test "read configuration from default file" do
    configuration = SolidQueue::Configuration.new(mode: :all)
    assert 3, configuration.runners.count
    assert_equal 2, configuration.workers.count
    assert configuration.dispatcher.present?
  end

  test "provide configuration as a hash and fill defaults" do
    background_worker = { queues: "background", polling_interval: 10 }
    config_as_hash = { workers: [ background_worker, background_worker ] }
    configuration = SolidQueue::Configuration.new(mode: :all, load_from: config_as_hash)

    assert_equal SolidQueue::Configuration::DISPATCHER_DEFAULTS[:polling_interval], configuration.dispatcher.polling_interval
    assert_equal 2, configuration.workers.count
    assert_equal [ "background" ], configuration.workers.flat_map(&:queues).uniq
    assert_equal [ 10 ], configuration.workers.map(&:polling_interval).uniq
  end

  test "max number of threads" do
    configuration = SolidQueue::Configuration.new(mode: :all)
    assert 7, configuration.max_number_of_threads
  end

  test "mulitple workers with the same configuration" do
    background_worker = { queues: "background", polling_interval: 10, processes: 3 }
    config_as_hash = { workers: [ background_worker ] }
    configuration = SolidQueue::Configuration.new(mode: :work, load_from: config_as_hash)

    assert_equal 3, configuration.workers.count
    assert_equal [ "background" ], configuration.workers.flat_map(&:queues).uniq
    assert_equal [ 10 ], configuration.workers.map(&:polling_interval).uniq
  end
end
