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

  test "warns if provided configuration file does not exist" do
    configuration = SolidQueue::Configuration.new(config_file: Pathname.new("/path/to/nowhere.yml"))

    assert configuration.valid?
    assert_includes configuration.warnings.full_messages,
      "Warning: provided configuration file '/path/to/nowhere.yml' does not exist. Falling back to default configuration."
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

  test "scheduler starts with dynamic_tasks_enabled even without static tasks" do
    configuration = SolidQueue::Configuration.new(
      recurring_schedule_file: config_file_path(:empty_configuration),
      scheduler: { dynamic_tasks_enabled: true }
    )

    assert_processes configuration, :scheduler, 1, dynamic_tasks_enabled: true
  end

  test "no scheduler without static tasks or dynamic_tasks_enabled" do
    configuration = SolidQueue::Configuration.new(
      recurring_schedule_file: config_file_path(:empty_configuration),
      scheduler: { dynamic_tasks_enabled: false }
    )

    assert_processes configuration, :scheduler, 0
  end

  test "no recurring tasks configuration when explicitly excluded" do
    configuration = SolidQueue::Configuration.new(dispatchers: [ { polling_interval: 0.1 } ], skip_recurring: true)
    assert_processes configuration, :dispatcher, 1, polling_interval: 0.1, recurring_tasks: nil
  end

  test "only_recurring runs just the scheduler process" do
    configuration = SolidQueue::Configuration.new(only_recurring: true)

    assert_equal 1, configuration.configured_processes.count
    assert_processes configuration, :scheduler, 1
    assert_processes configuration, :worker, 0
    assert_processes configuration, :dispatcher, 0
    assert configuration.valid?
  end

  test "only_recurring ignores workers and dispatchers from the config file" do
    configuration = SolidQueue::Configuration.new(only_recurring: true)

    assert_processes configuration, :worker, 0
    assert_processes configuration, :dispatcher, 0
    assert_processes configuration, :scheduler, 1

    scheduler = configuration.configured_processes.first.instantiate
    assert_has_recurring_task scheduler, key: "periodic_store_result", class_name: "StoreResultJob", schedule: "every second"
  end

  test "only_recurring when SOLID_QUEUE_ONLY_RECURRING environment variable is set" do
    with_env("SOLID_QUEUE_ONLY_RECURRING" => "true") do
      configuration = SolidQueue::Configuration.new

      assert_equal 1, configuration.configured_processes.count
      assert_processes configuration, :scheduler, 1
      assert_processes configuration, :worker, 0
      assert_processes configuration, :dispatcher, 0
    end
  end

  test "only_recurring with skip_recurring is invalid" do
    configuration = SolidQueue::Configuration.new(only_recurring: true, skip_recurring: true)

    assert_not configuration.valid?
    assert_equal [ "No processes configured" ], configuration.errors.full_messages
  end

  test "skip recurring tasks when SOLID_QUEUE_SKIP_RECURRING environment variable is set" do
    with_env("SOLID_QUEUE_SKIP_RECURRING" => "true") do
      configuration = SolidQueue::Configuration.new(dispatchers: [ { polling_interval: 0.1 } ])
      assert_processes configuration, :dispatcher, 1, polling_interval: 0.1
      assert_processes configuration, :scheduler, 0
    end
  end

  test "include recurring tasks when SOLID_QUEUE_SKIP_RECURRING environment variable is false" do
    with_env("SOLID_QUEUE_SKIP_RECURRING" => "false") do
      configuration = SolidQueue::Configuration.new(dispatchers: [ { polling_interval: 0.1 } ])
      assert_processes configuration, :dispatcher, 1, polling_interval: 0.1
      assert_processes configuration, :scheduler, 1
    end
  end

  test "include recurring tasks when SOLID_QUEUE_SKIP_RECURRING environment variable is not set" do
    with_env("SOLID_QUEUE_SKIP_RECURRING" => nil) do
      configuration = SolidQueue::Configuration.new(dispatchers: [ { polling_interval: 0.1 } ])
      assert_processes configuration, :dispatcher, 1, polling_interval: 0.1
      assert_processes configuration, :scheduler, 1
    end
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

    configuration = SolidQueue::Configuration.new(recurring_schedule_file: config_file_path(:empty_recurring))
    assert configuration.valid?
    assert_match(/provided configuration file '[^']+' does not exist\./, configuration.warnings.full_messages.join)

    assert SolidQueue::Configuration.new(skip_recurring: true).valid?

    configuration = SolidQueue::Configuration.new(recurring_schedule_file: config_file_path(:recurring_with_production_only))
    assert configuration.valid?
    assert_processes configuration, :scheduler, 0

    configuration = SolidQueue::Configuration.new(recurring_schedule_file: config_file_path(:recurring_with_empty))
    assert configuration.valid?
    assert_processes configuration, :scheduler, 0
    assert_match(/provided configuration file '[^']+' does not exist\./, configuration.warnings.full_messages.join)

    # No processes
    configuration = SolidQueue::Configuration.new(skip_recurring: true, dispatchers: [], workers: [])
    assert_not configuration.valid?
    assert_equal [ "No processes configured" ], configuration.errors.full_messages

    # Not enough DB connections: still valid so boot is not blocked
    configuration = SolidQueue::Configuration.new(workers: [ { queues: "background", threads: 50, polling_interval: 10 } ])
    assert configuration.valid?
  end

  test "reports an undersized thread pool as a warning rather than an error" do
    configuration = SolidQueue::Configuration.new(workers: [ { queues: "background", threads: 50, polling_interval: 10 } ], skip_recurring: true)

    assert configuration.valid?
    assert_equal 1, configuration.warnings.size
    assert_match /Solid Queue is configured to use \d+ threads but the database connection pool is \d+\. Increase it in `config\/database.yml`/, configuration.warnings.full_messages.first
  end

  test "has no warnings when the database connection pool is large enough" do
    configuration = SolidQueue::Configuration.new(workers: [ { queues: "background", threads: 1, polling_interval: 10 } ], skip_recurring: true)

    assert configuration.valid?
    assert_empty configuration.warnings
  end

  test "does not duplicate warnings when validated more than once" do
    configuration = SolidQueue::Configuration.new(workers: [ { queues: "background", threads: 50, polling_interval: 10 } ], skip_recurring: true)

    3.times { configuration.valid? }

    assert_equal 1, configuration.warnings.size
  end

  test "check prints a success message and returns true for a valid configuration" do
    out, err = capture_io do
      assert SolidQueue::Configuration.new(skip_recurring: true).check
    end

    assert_match "Solid Queue configuration is valid.", out
    assert_empty err
  end

  test "check prints warnings to stderr on the valid path" do
    out, err = capture_io do
      assert SolidQueue::Configuration.new(workers: [ { queues: "background", threads: 50, polling_interval: 10 } ], skip_recurring: true).check
    end

    assert_match "Solid Queue configuration is valid.", out
    assert_match /Solid Queue is configured to use \d+ threads but the database connection pool is \d+/, err
  end

  test "check prints errors to stderr and returns false for an invalid configuration" do
    out, err = capture_io do
      assert_not SolidQueue::Configuration.new(recurring_schedule_file: config_file_path(:recurring_with_invalid)).check
    end

    assert_match "Solid Queue configuration is invalid:", err
    assert_match "periodic_invalid_class", err
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
