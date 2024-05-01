# frozen_string_literal: true

class SolidQueue::InstallGenerator < Rails::Generators::Base
  source_root File.expand_path("templates", __dir__)

  class_option :skip_migrations, type: :boolean, default: nil, desc: "Skip migrations"
  class_option :database, type: :string, aliases: %i(--db), desc: "The database for your migration. By default, the current environment's primary database is used."

  def add_solid_queue
    if (env_config = Pathname(destination_root).join("config/environments/production.rb")).exist?
      gsub_file env_config, /(# )?config\.active_job\.queue_adapter\s+=.*/, "config.active_job.queue_adapter = :solid_queue"
    end

    copy_file "config.yml", "config/solid_queue.yml"
  end

  def create_migrations
    unless options[:skip_migrations]
      rails_command "railties:install:migrations FROM=solid_queue DATABASE=#{options[:database]}", inline: true
    end
  end
end
