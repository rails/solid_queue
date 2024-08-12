require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  test "default configuration to process all queues and dispatch" do
    configuration = stub_const(SolidQueue::Configuration, :DEFAULT_CONFIG_FILE_PATH, "non/existent/path") do
      SolidQueue::Configuration.new
    end

    assert_equal 2, configuration.configured_processes.count
    assert_processes configuration, :worker, 1, queues: [ "*" ]
    assert_processes configuration, :dispatcher, 1, batch_size: SolidQueue::Configuration::DISPATCHER_DEFAULTS[:batch_size]
  end

  test "read configuration from default file" do
    configuration = SolidQueue::Configuration.new
    assert 3, configuration.configured_processes.count
    assert_processes configuration, :worker, 2
    assert_processes configuration, :dispatcher, 1
  end

  test "provide configuration as a hash and fill defaults" do
    background_worker = { queues: "background", polling_interval: 10 }
    dispatcher = { batch_size: 100 }
    config_as_hash = { workers: [ background_worker, background_worker ], dispatchers: [ dispatcher ] }
    configuration = SolidQueue::Configuration.new(load_from: config_as_hash)

    assert_processes configuration, :dispatcher, 1, polling_interval: SolidQueue::Configuration::DISPATCHER_DEFAULTS[:polling_interval], batch_size: 100
    assert_processes configuration, :worker, 2, queues: [ "background" ], polling_interval: 10

    config_as_hash = { workers: [ background_worker, background_worker ] }
    configuration = SolidQueue::Configuration.new(load_from: config_as_hash)

    assert_processes configuration, :dispatcher, 0
    assert_processes configuration, :worker, 2
  end

  test "max number of threads" do
    configuration = SolidQueue::Configuration.new
    assert 7, configuration.max_number_of_threads
  end

  test "mulitple workers with the same configuration" do
    background_worker = { queues: "background", polling_interval: 10, processes: 3 }
    config_as_hash = { workers: [ background_worker ] }
    configuration = SolidQueue::Configuration.new(load_from: config_as_hash)

    assert_equal 3, configuration.configured_processes.count
    assert_processes configuration, :worker, 3, queues: [ "background" ], polling_interval: 10
  end

  test "ignore processes option on async mode" do
    background_worker = { queues: "background", polling_interval: 10, processes: 3 }
    config_as_hash = { workers: [ background_worker ] }
    configuration = SolidQueue::Configuration.new(mode: :async, load_from: config_as_hash)

    assert_equal 1, configuration.configured_processes.count
    assert_processes configuration, :worker, 1, queues: [ "background" ], polling_interval: 10
  end

  private
    def assert_processes(configuration, kind, count, **attributes)
      processes = configuration.configured_processes.select { |p| p.kind == kind }.map(&:instantiate)
      assert_equal count, processes.size

      attributes.each do |attr, value|
        assert_equal value, processes.map { |p| p.public_send(attr) }.first
      end
    end
end
