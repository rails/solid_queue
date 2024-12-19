# frozen_string_literal: true

module ConfigurationTestHelper
  def config_file_path(name)
    Rails.root.join("config/#{name}.yml")
  end
end
