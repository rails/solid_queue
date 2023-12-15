# frozen_string_literal: true

class SolidQueue::InstallGenerator < Rails::Generators::Base
  class_option :skip_migrations, type: :boolean, default: nil, desc: "Skip migrations"

  def add_solid_queue
    %w[ development test production ].each do |env_name|
      if (env_config = Pathname(destination_root).join("config/environments/#{env_name}.rb")).exist?
        gsub_file env_config, /(# )?config\.active_job\.queue_adapter\s+=.*/, "config.active_job.queue_adapter = :solid_queue"
      end
    end
  end

  def create_migrations
    unless options[:skip_migrations]
      rails_command "railties:install:migrations FROM=solid_queue", inline: true
    end
  end
end
