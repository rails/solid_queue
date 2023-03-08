# frozen_string_literal: true

class SolidQueue::Configuration
  DISPATCHER_DEFAULTS = {
    worker_count: 5,
    polling_interval: 0.1,
  }

  SCHEDULER_DEFAULTS = {
    batch_size: 500,
    polling_interval: 300
  }

  def initialize(file_or_hash = nil)
    @raw_config = config_from(file_or_hash)
  end

  def queues
    @queues ||= (raw_config[:queues] || {}).each_with_object({}) do |(queue_name, options), hsh|
      hsh[queue_name] = options.merge(queue_name: queue_name.to_s).with_defaults(DISPATCHER_DEFAULTS)
    end.tap do |queues|
      queues[SolidQueue::Job::DEFAULT_QUEUE_NAME] ||= DISPATCHER_DEFAULTS
    end.deep_symbolize_keys
  end

  def scheduler_disabled?
    raw_config.dig(:scheduler, :disabled)
  end

  def scheduler_options
    (raw_config[:scheduler] || {}).with_defaults(SCHEDULER_DEFAULTS)
  end

  private
    attr_reader :raw_config

    def config_from(file_or_hash, env: Rails.env)
      config = load_config_from(file_or_hash)
      config[env.to_sym] ? config[env.to_sym] : config
    end

    def load_config_from(file_or_hash)
      case file_or_hash
      when Pathname then load_config_file file_or_hash
      when String   then load_config_file Pathname.new(file_or_hash)
      when NilClass then load_config_file default_config_file
      when Hash     then file_or_hash.dup
      else          raise "Solid Queue cannot be initialized with #{file_or_hash.inspect}"
      end
    end

    def load_config_file(file)
      if file.exist?
        ActiveSupport::ConfigurationFile.parse(file).deep_symbolize_keys
      else
        raise "Configuration file not found in #{file}"
      end
    end

    def default_config_file
      Rails.root.join("config/solid_queue.yml").tap do |config_file|
        raise "Configuration for Solid Queue not found in #{config_file}" unless config_file.exist?
      end
    end
end
