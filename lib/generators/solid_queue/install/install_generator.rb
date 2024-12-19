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

  def configure_adapter_and_database
    pathname = Pathname(destination_root).join("config/environments/production.rb")

    gsub_file pathname, /\n\s*config\.solid_queue\.connects_to\s+=.*\n/, "\n", verbose: false
    gsub_file pathname, /(# )?config\.active_job\.queue_adapter\s+=.*\n/,
      "config.active_job.queue_adapter = :solid_queue\n" +
      "  config.solid_queue.connects_to = { database: { writing: :queue } }\n"
  end
end
