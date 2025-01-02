require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  test "default configuration to process all queues and dispatch" do
    configuration = SolidQueue::Configuration.new(config_file: nil)

    assert_equal 3, configuration.configured_processes.count
    assert_processes configuration, :worker, 1, queues: "*"
    assert_processes configuration, :dispatcher, 1, batch_size: SolidQueue::Configuration::DISPATCHER_DEFAULTS[:batch_size]
    assert_processes configuration, :scheduler, 1
  end

  test "default configuration when config given doesn't include any configuration" do
    configuration = SolidQueue::Configuration.new(config_file: config_file_path(:invalid_configuration), skip_recurring: true)

    assert_equal 2, configuration.configured_processes.count
    assert_processes configuration, :worker, 1, queues: "*"
    assert_processes configuration, :dispatcher, 1, batch_size: SolidQueue::Configuration::DISPATCHER_DEFAULTS[:batch_size]
  end

  test "default configuration when config given is empty" do
    configuration = SolidQueue::Configuration.new(config_file: config_file_path(:empty_configuration), recurring_schedule_file: config_file_path(:empty_configuration))

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
    configuration = SolidQueue::Configuration.new(config_file: config_file_path(:alternative_configuration), only_work: true)

    assert 3, configuration.configured_processes.count
    assert_processes configuration, :worker, 3, processes: 1, polling_interval: 0.1, queues: %w[ queue_1 queue_2 queue_3 ], threads: [ 1, 2, 3 ]
  end

  test "provide configuration as a hash and fill defaults" do
    background_worker = { queues: "background", polling_interval: 10 }
    dispatcher = { batch_size: 100 }
    configuration = SolidQueue::Configuration.new(workers: [ background_worker, background_worker ], dispatchers: [ dispatcher ])

    assert_processes configuration, :dispatcher, 1, polling_interval: SolidQueue::Configuration::DISPATCHER_DEFAULTS[:polling_interval], batch_size: 100
    assert_processes configuration, :worker, 2, queues: "background", polling_interval: 10

    configuration = SolidQueue::Configuration.new(workers: [ background_worker, background_worker ], skip_recurring: true)

    assert_processes configuration, :dispatcher, 0
    assert_processes configuration, :worker, 2
  end

  test "mulitple workers with the same configuration" do
    background_worker = { queues: "background", polling_interval: 10, processes: 3 }
    configuration = SolidQueue::Configuration.new(workers: [ background_worker ])

    assert_processes configuration, :worker, 3, queues: "background", polling_interval: 10
  end

  test "recurring tasks configuration with one dispatcher" do
    configuration = SolidQueue::Configuration.new(dispatchers: [ { polling_interval: 0.1 } ])

    assert_processes configuration, :dispatcher, 1, polling_interval: 0.1
    assert_processes configuration, :scheduler, 1

    scheduler = configuration.configured_processes.second.instantiate
    assert_has_recurring_task scheduler, key: "periodic_store_result", class_name: "StoreResultJob", schedule: "every second"
  end

  test "recurring tasks configuration adds a scheduler" do
    configuration = SolidQueue::Configuration.new(dispatchers: [])

    assert_processes configuration, :scheduler, 1

    scheduler = configuration.configured_processes.first.instantiate
    assert_has_recurring_task scheduler, key: "periodic_store_result", class_name: "StoreResultJob", schedule: "every second"
  end

  test "no recurring tasks configuration when explicitly excluded" do
    configuration = SolidQueue::Configuration.new(dispatchers: [ { polling_interval: 0.1 } ], skip_recurring: true)
    assert_processes configuration, :dispatcher, 1, polling_interval: 0.1, recurring_tasks: nil
  end

  test "validate configuration" do
    # Valid and invalid recurring tasks
    configuration = SolidQueue::Configuration.new(recurring_schedule_file: config_file_path(:recurring_with_invalid))
    assert_not configuration.valid?
    assert configuration.errors.full_messages.one?
    error = configuration.errors.full_messages.first

    assert error.include?("Invalid recurring tasks")
    assert error.include?("periodic_invalid_class: Class name doesn't correspond to an existing class")
    assert error.include?("periodic_incorrect_schedule: Schedule is not a supported recurring schedule")

    assert SolidQueue::Configuration.new(recurring_schedule_file: config_file_path(:empty_recurring)).valid?
    assert SolidQueue::Configuration.new(skip_recurring: true).valid?

    configuration = SolidQueue::Configuration.new(recurring_schedule_file: config_file_path(:recurring_with_production_only))
    assert configuration.valid?
    assert_processes configuration, :scheduler, 0

    configuration = SolidQueue::Configuration.new(recurring_schedule_file: config_file_path(:recurring_with_empty))
    assert configuration.valid?
    assert_processes configuration, :scheduler, 0

    # No processes
    configuration = SolidQueue::Configuration.new(skip_recurring: true, dispatchers: [], workers: [])
    assert_not configuration.valid?
    assert_equal [ "No processes configured" ], configuration.errors.full_messages

    # Not enough DB connections
    configuration = SolidQueue::Configuration.new(workers: [ { queues: "background", threads: 50, polling_interval: 10 } ])
    assert_not configuration.valid?
    assert_match /Solid Queue is configured to use \d+ threads but the database connection pool is \d+. Increase it in `config\/database.yml`/,
      configuration.errors.full_messages.first
  end

  private
    def assert_processes(configuration, kind, count, **attributes)
      processes = configuration.configured_processes.select { |p| p.kind == kind }
      assert_equal count, processes.size

      attributes.each do |attr, expected_value|
        value = processes.map { |p| p.attributes[attr] }
        unless expected_value.is_a?(Array)
          value = value.first
        end

        assert_equal_value expected_value, value
      end
    end

    def assert_has_recurring_task(scheduler, key:, **attributes)
      assert_equal 1, scheduler.recurring_schedule.configured_tasks.count
      task = scheduler.recurring_schedule.configured_tasks.detect { |t| t.key == key }

      attributes.each do |attr, value|
        assert_equal_value value, task.public_send(attr)
      end
    end

    def assert_equal_value(expected_value, value)
      if expected_value.nil?
        assert_nil value
      else
        assert_equal expected_value, value
      end
    end
end
