require_relative "lib/active_job/database_queue/version"

Gem::Specification.new do |spec|
  spec.name        = "active_job-database_queue"
  spec.version     = ActiveJob::DatabaseQueue::VERSION
  spec.authors     = ["Rosa Gutierrez"]
  spec.email       = ["rosa@37signals.com"]
  spec.homepage    = "http://github.com/basecamp/active_job-database_queue"
  spec.summary     = "Database-backed Active Job backend."
  spec.description = "Database-backed Active Job backend."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "http://github.com/basecamp/active_job-database_queue"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 7.0.3.1"
end
