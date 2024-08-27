# frozen_string_literal: true

class SolidQueue::InstallGenerator < Rails::Generators::Base
  source_root File.expand_path("templates", __dir__)

  class_option :skip_adapter, type: :boolean, default: nil, desc: "Skip setting Solid Queue as the Active Job's adapter"
  class_option :database, type: :string, default: nil, desc: "The database to use for migrations, if different from the primary one."

  def add_solid_queue
    unless options[:skip_adapter]
      if (env_config = Pathname(destination_root).join("config/environments/production.rb")).exist?
        say "Setting solid_queue as Active Job's queue adapter"
        gsub_file env_config, /(# )?config\.active_job\.queue_adapter\s+=.*/, "config.active_job.queue_adapter = :solid_queue"
      end
    end

    say "Copying sample configuration"
    copy_file "config.yml", "config/solid_queue.yml"
  end

  def create_migrations
    say "Installing database migrations"
    arguments = [ "FROM=solid_queue" ]
    arguments << "DATABASE=#{options[:database]}" if options[:database].present?
    rails_command "railties:install:migrations #{arguments.join(" ")}", inline: true
  end
end
