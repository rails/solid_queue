# frozen_string_literal: true

module SolidQueue
  class Configuration
    include ActiveModel::Model

    validate :ensure_configured_processes
    validate :ensure_valid_recurring_tasks
    validate :ensure_correctly_sized_database_pool
    validate :ensure_valid_worker_execution_modes
    validate :ensure_async_workers_use_capacity_aliases
    validate :ensure_async_workers_have_required_dependency
    validate :ensure_async_workers_use_supported_isolation_level

    class Process < Struct.new(:kind, :attributes)
      def instantiate
        "SolidQueue::#{kind.to_s.titleize}".safe_constantize.new(**attributes)
      end
    end

    WORKER_DEFAULTS = {
      queues: "*",
      threads: 3,
      processes: 1,
      polling_interval: 0.1,
      execution_mode: :thread
    }

    DISPATCHER_DEFAULTS = {
      batch_size: 500,
      polling_interval: 1,
      concurrency_maintenance: true,
      concurrency_maintenance_interval: 600
    }

    SCHEDULER_DEFAULTS = {
      polling_interval: 5,
      dynamic_tasks_enabled: false
    }

    DEFAULT_CONFIG_FILE_PATH = "config/queue.yml"
    DEFAULT_RECURRING_SCHEDULE_FILE_PATH = "config/recurring.yml"
    ASYNC_QUERY_SCOPED_CONNECTIONS_VERSION = Gem::Version.new("7.2.0")

    def initialize(**options)
      @options = options.with_defaults(default_options)
    end

    def configured_processes
      if only_work? then workers
      else
        dispatchers + workers + schedulers
      end
    end

    def error_messages
      if configured_processes.none?
        "No workers or processed configured. Exiting..."
      else
        error_messages = invalid_tasks.map do |task|
            all_messages = task.errors.full_messages.map { |msg| "\t#{msg}" }.join("\n")
            "#{task.key}:\n#{all_messages}"
          end
          .join("\n")

        "Invalid processes configured:\n#{error_messages}"
      end
    end

    def mode
      @options[:mode].to_s.inquiry
    end

    def standalone?
      mode.fork? || @options[:standalone]
    end

    private
      attr_reader :options

      def ensure_configured_processes
        unless configured_processes.any?
          errors.add(:base, "No processes configured")
        end
      end

      def ensure_valid_recurring_tasks
        unless skip_recurring_tasks? || invalid_tasks.none?
          error_messages = invalid_tasks.map do |task|
            "- #{task.key}: #{task.errors.full_messages.join(", ")}"
          end

          errors.add(:base, "Invalid recurring tasks:\n#{error_messages.join("\n")}")
        end
      end

      def ensure_correctly_sized_database_pool
        if (db_pool_size = SolidQueue::Record.connection_pool&.size) && db_pool_size < estimated_database_pool_size
          errors.add(:base, "Solid Queue requires at least #{estimated_database_pool_size} database connections " +
            "for the configured workers, but the queue database connection pool is #{db_pool_size}. " +
            "Increase it in `config/database.yml`")
        end
      end

      def ensure_valid_worker_execution_modes
        workers_options.each do |options|
          SolidQueue::ExecutionPools.normalize_mode(options[:execution_mode] || WORKER_DEFAULTS[:execution_mode])
        rescue ArgumentError => error
          errors.add(:base, error.message)
        end
      end

      def ensure_async_workers_use_capacity_aliases
        workers_options.each do |options|
          if async_worker?(options) && options.key?(:threads)
            errors.add(:base, "Async workers do not accept `threads`. Use `capacity` or `fibers` instead.")
          end
        end
      end

      def ensure_async_workers_have_required_dependency
        return unless workers_options.any? { |options| async_worker?(options) }

        SolidQueue::ExecutionPools::AsyncPool.ensure_dependency!
      rescue LoadError => error
        errors.add(:base, error.message)
      end

      def ensure_async_workers_use_supported_isolation_level
        return unless workers_options.any? { |options| async_worker?(options) }

        SolidQueue::ExecutionPools::AsyncPool.ensure_supported_isolation_level!
      rescue ArgumentError => error
        errors.add(:base, error.message)
      end

      def default_options
        {
          mode: ENV["SOLID_QUEUE_SUPERVISOR_MODE"] || :fork,
          standalone: true,
          config_file: Rails.root.join(ENV["SOLID_QUEUE_CONFIG"] || DEFAULT_CONFIG_FILE_PATH),
          recurring_schedule_file: Rails.root.join(ENV["SOLID_QUEUE_RECURRING_SCHEDULE"] || DEFAULT_RECURRING_SCHEDULE_FILE_PATH),
          only_work: false,
          only_dispatch: false,
          skip_recurring: ActiveModel::Type::Boolean.new.cast(ENV["SOLID_QUEUE_SKIP_RECURRING"])
        }
      end

      def invalid_tasks
        recurring_tasks.select(&:invalid?)
      end

      def only_work?
        options[:only_work]
      end

      def only_dispatch?
        options[:only_dispatch]
      end

      def skip_recurring_tasks?
        options[:skip_recurring] || only_work?
      end

      def workers
        workers_options.flat_map do |worker_options|
          processes = if mode.fork?
            worker_options.fetch(:processes, WORKER_DEFAULTS[:processes])
          else
            1
          end

          defaults = worker_defaults_for(worker_options)
          processes.times.map { Process.new(:worker, worker_options.with_defaults(defaults)) }
        end
      end

      def dispatchers
        dispatchers_options.map do |dispatcher_options|
          Process.new :dispatcher, dispatcher_options.with_defaults(DISPATCHER_DEFAULTS)
        end
      end

      def schedulers
        return [] if skip_recurring_tasks?

        if recurring_tasks.any? || dynamic_recurring_tasks_enabled?
          [ Process.new(:scheduler, { recurring_tasks: recurring_tasks, **scheduler_options.with_defaults(SCHEDULER_DEFAULTS) }) ]
        else
          []
        end
      end

      def workers_options
        @workers_options ||= processes_config.fetch(:workers, [])
          .map { |options| normalize_worker_options(options) }
      end

      def dispatchers_options
        @dispatchers_options ||= processes_config.fetch(:dispatchers, [])
          .map { |options| options.dup.symbolize_keys }
      end

      def scheduler_options
        @scheduler_options ||= processes_config.fetch(:scheduler, {}).dup.symbolize_keys
      end

      def dynamic_recurring_tasks_enabled?
        scheduler_options.fetch(:dynamic_tasks_enabled, SCHEDULER_DEFAULTS[:dynamic_tasks_enabled])
      end

      def recurring_tasks
        @recurring_tasks ||= recurring_tasks_config.map do |id, options|
          RecurringTask.from_configuration(id, **options.merge(static: true)) if options&.has_key?(:schedule)
        end.compact
      end

      def processes_config
        @processes_config ||= config_from \
          options.slice(:workers, :dispatchers, :scheduler).presence || options[:config_file],
          keys: [ :workers, :dispatchers, :scheduler ],
          fallback: {
            workers: [ WORKER_DEFAULTS ],
            dispatchers: [ DISPATCHER_DEFAULTS ],
            scheduler: SCHEDULER_DEFAULTS
          }
      end

      def recurring_tasks_config
        @recurring_tasks_config ||= begin
          config_from options[:recurring_schedule_file]
        end
      end

      def config_from(file_or_hash, keys: [], fallback: {}, env: Rails.env)
        load_config_from(file_or_hash).then do |config|
          config = config[env.to_sym] ? config[env.to_sym] : config
          config = config.slice(*keys) if keys.any? && config.present?

          if config.empty? then fallback
          else
            config
          end
        end
      end

      def load_config_from(file_or_hash)
        case file_or_hash
        when Hash
          file_or_hash.dup
        when Pathname, String
          load_config_from_file Pathname.new(file_or_hash)
        when NilClass
          {}
        else
          raise "Solid Queue cannot be initialized with #{file_or_hash.inspect}"
        end
      end

      def load_config_from_file(file)
        if file.exist?
          ActiveSupport::ConfigurationFile.parse(file).deep_symbolize_keys
        else
          puts "[solid_queue] WARNING: Provided configuration file '#{file}' does not exist. Falling back to default configuration."
          {}
        end
      end

      def estimated_database_pool_size
        worker_pool_size = workers_options.map { |options| estimated_database_pool_size_for_worker(options) }.max
        worker_pool_size || 1
      end

      def estimated_database_pool_size_for_worker(options)
        estimated_execution_connections_for_worker(options) + 2
      end

      def normalize_worker_options(options)
        options = options.dup.symbolize_keys
        options[:execution_mode] = normalized_worker_execution_mode(options)
        options[:capacity] = worker_capacity(options) if options.key?(:capacity) || options.key?(:fibers)
        options[:threads] = worker_capacity(options) unless async_worker?(options) && !options.key?(:threads)
        options
      end

      def worker_capacity(options)
        options[:capacity] || options[:fibers] || options[:threads] || WORKER_DEFAULTS[:threads]
      end

      def normalized_worker_execution_mode(options)
        SolidQueue::ExecutionPools.normalize_mode(options[:execution_mode] || WORKER_DEFAULTS[:execution_mode])
      rescue ArgumentError
        options[:execution_mode] || WORKER_DEFAULTS[:execution_mode]
      end

      def estimated_execution_connections_for_worker(options)
        async_worker?(options) ? async_execution_connections_for_worker(options) : worker_capacity(options)
      end

      def async_execution_connections_for_worker(options)
        async_jobs_release_connections_between_queries? ? 1 : worker_capacity(options)
      end

      def async_jobs_release_connections_between_queries?
        ActiveRecord.gem_version >= ASYNC_QUERY_SCOPED_CONNECTIONS_VERSION
      end

      def async_worker?(options)
        normalized_worker_execution_mode(options) == :async
      end

      def worker_defaults_for(options)
        if async_worker?(options)
          WORKER_DEFAULTS.except(:threads).tap do |defaults|
            defaults[:capacity] = WORKER_DEFAULTS[:threads] unless options.key?(:threads)
          end
        else
          WORKER_DEFAULTS
        end
      end
  end
end
