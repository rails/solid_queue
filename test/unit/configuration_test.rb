require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  test "default configuration to process all queues and dispatch" do
    configuration = stub_const(SolidQueue::Configuration, :DEFAULT_CONFIG_FILE_PATH, "non/existent/path") do
      SolidQueue::Configuration.new
    end

    assert_equal 2, configuration.configured_processes.count
    assert_processes configuration, :worker, 1, queues: "*"
    assert_processes configuration, :dispatcher, 1, batch_size: SolidQueue::Configuration::DISPATCHER_DEFAULTS[:batch_size]
  end

  test "default configuration when config given doesn't include any configuration" do
    configuration = SolidQueue::Configuration.new(random_wrong_key: :random_value)

    assert_equal 2, configuration.configured_processes.count
    assert_processes configuration, :worker, 1, queues: "*"
    assert_processes configuration, :dispatcher, 1, batch_size: SolidQueue::Configuration::DISPATCHER_DEFAULTS[:batch_size]
  end

  test "default configuration when config given is empty" do
    configuration = SolidQueue::Configuration.new(config_file: Rails.root.join("config/empty_configuration.yml"))

    assert_equal 2, configuration.configured_processes.count
    assert_processes configuration, :worker, 1, queues: "*"
    assert_processes configuration, :dispatcher, 1, batch_size: SolidQueue::Configuration::DISPATCHER_DEFAULTS[:batch_size]
  end

  test "read configuration from default file" do
    configuration = SolidQueue::Configuration.new
    assert 3, configuration.configured_processes.count
    assert_processes configuration, :worker, 2
    assert_processes configuration, :dispatcher, 1
  end

  test "read configuration from provided file" do
    configuration = SolidQueue::Configuration.new(config_file: Rails.root.join("config/alternative_configuration.yml"))

    assert 3, configuration.configured_processes.count
    assert_processes configuration, :worker, 3, processes: 1, polling_interval: 0.1, queues: %w[ queue_1 queue_2 queue_3 ], threads: [ 1, 2, 3 ]
  end

  test "provide configuration as a hash and fill defaults" do
    background_worker = { queues: "background", polling_interval: 10 }
    dispatcher = { batch_size: 100 }
    configuration = SolidQueue::Configuration.new(workers: [ background_worker, background_worker ], dispatchers: [ dispatcher ])

    assert_processes configuration, :dispatcher, 1, polling_interval: SolidQueue::Configuration::DISPATCHER_DEFAULTS[:polling_interval], batch_size: 100
    assert_processes configuration, :worker, 2, queues: "background", polling_interval: 10

    configuration = SolidQueue::Configuration.new(workers: [ background_worker, background_worker ])

    assert_processes configuration, :dispatcher, 0
    assert_processes configuration, :worker, 2
  end

  test "max number of threads" do
    configuration = SolidQueue::Configuration.new
    assert 7, configuration.max_number_of_threads
  end

  test "mulitple workers with the same configuration" do
    background_worker = { queues: "background", polling_interval: 10, processes: 3 }
    configuration = SolidQueue::Configuration.new(workers: [ background_worker ])

    assert_equal 3, configuration.configured_processes.count
    assert_processes configuration, :worker, 3, queues: "background", polling_interval: 10
  end

  private
    def assert_processes(configuration, kind, count, **attributes)
      processes = configuration.configured_processes.select { |p| p.kind == kind }
      assert_equal count, processes.size

      attributes.each do |attr, expected_value|
        value = processes.map { |p| p.attributes.fetch(attr) }
        unless expected_value.is_a?(Array)
          value = value.first
        end

        assert_equal expected_value, value
      end
    end
end
