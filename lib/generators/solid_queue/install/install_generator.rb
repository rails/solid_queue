# frozen_string_literal: true

class SolidQueue::InstallGenerator < Rails::Generators::Base
  source_root File.expand_path("templates", __dir__)

  def copy_files
    template "config/queue.yml"
    template "config/recurring.yml"
    template "db/queue_schema.rb"
    template "bin/jobs"
    chmod "bin/jobs", 0755 & ~File.umask, verbose: false
  end

  def configure_active_job_adapter
    production_rb = Pathname(destination_root).join("config/environments/production.rb")

    # Replace or set `config.active_job.queue_adapter`
    gsub_file Pathname(destination_root).join("config/environments/production.rb"),
    /config\.active_job\.queue_adapter\s+=.*/,
    "config.active_job.queue_adapter = :solid_queue"

    # Inject `config.solid_queue.connects_to` if not already present
    gsub_file Pathname(destination_root).join("config/environments/production.rb"),
    /^\s*config\.solid_queue\.connects_to\s+=\s+\{.*\}\n/,
    "",
    verbose: false # If found, do nothing

    inject_into_file Pathname(destination_root).join("config/environments/production.rb"),
    "\n  config.solid_queue.connects_to = { database: { writing: :queue } }",
    after: /config\.active_job\.queue_adapter\s+=.*/
  end
end
