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

    # Replace the active_job queue_adapter line
    gsub_file(production_rb, /(# )?config\.active_job\.queue_adapter\s+=.*/, "config.active_job.queue_adapter = :solid_queue")

    # Add the solid_queue connects_to line if it doesn't exist
    unless File.foreach(production_rb).any? { |line| line.include?("config.solid_queue.connects_to = { database: { writing: :queue } }") }
      inject_into_file(production_rb, "\n  config.solid_queue.connects_to = { database: { writing: :queue } }", after: "config.active_job.queue_adapter = :solid_queue\n")
    end
  end
end
