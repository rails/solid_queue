# frozen_string_literal: true

class SolidQueue::InstallGenerator < Rails::Generators::Base
  source_root File.expand_path("templates", __dir__)

  class_option :skip_migrations, type: :boolean, default: nil, desc: "Skip migrations"

  def add_solid_queue
    %w[ development test production ].each do |env_name|
      if (env_config = Pathname(destination_root).join("config/environments/#{env_name}.rb")).exist?
        gsub_file env_config, /(# )?config\.active_job\.queue_adapter\s+=.*/, "config.active_job.queue_adapter = :solid_queue"
      end
    end

    copy_file "config.yml", "config/solid_queue.yml"
  end

  def create_migrations
    unless options[:skip_migrations]
      rails_command "railties:install:migrations FROM=solid_queue", inline: true
    end
  end
end
