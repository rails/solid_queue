# frozen_string_literal: true

module ConfigurationTestHelper
  def config_file_path(name)
    Rails.root.join("config/#{name}.yml")
  end

  def with_env(env_vars)
    original_values = {}
    env_vars.each do |key, value|
      original_values[key] = ENV[key]
      ENV[key] = value
    end

    yield
  ensure
    original_values.each do |key, value|
      ENV[key] = value
    end
  end
end
