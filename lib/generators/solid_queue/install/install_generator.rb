# frozen_string_literal: true

class SolidQueue::InstallGenerator < Rails::Generators::Base
  source_root File.expand_path("templates", __dir__)

  def copy_files
    template "config/solid_queue.yml"
    template "db/queue_schema.rb"
    template "bin/jobs"
  end

  def configure_active_job_adapter
    gsub_file Pathname(destination_root).join("config/environments/production.rb"),
      /(# )?config\.active_job\.queue_adapter\s+=.*/,
      "config.active_job.queue_adapter = :solid_queue\n" +
      "  config.solid_queue.connects_to = { database: { writing: :queue } }\n"
  end
end
