require_relative "lib/solid_queue/version"

Gem::Specification.new do |spec|
  spec.name        = "solid_queue"
  spec.version     = SolidQueue::VERSION
  spec.authors     = [ "Rosa Gutierrez" ]
  spec.email       = [ "rosa@37signals.com" ]
  spec.homepage    = "https://github.com/rails/solid_queue"
  spec.summary     = "Database-backed Active Job backend."
  spec.description = "Database-backed Active Job backend."
  spec.license     = "MIT"

  spec.post_install_message = <<~MESSAGE
    Upgrading from Solid Queue < 1.0? Check details on breaking changes and upgrade instructions
    --> https://github.com/rails/solid_queue/blob/main/UPGRADING.md
  MESSAGE

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rails/solid_queue"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md", "UPGRADING.md"]
  end

  rails_version = ">= 7.1"
  spec.required_ruby_version = '>= 3.1'
  spec.add_dependency "activerecord", rails_version
  spec.add_dependency "activejob", rails_version
  spec.add_dependency "railties", rails_version
  spec.add_dependency "concurrent-ruby", ">= 1.3.1"
  spec.add_dependency "fugit", "~> 1.11.0"
  spec.add_dependency "thor", "~> 1.3.1"

  spec.add_development_dependency "debug", "~> 1.9"
  spec.add_development_dependency "mocha"
  spec.add_development_dependency "puma"
  spec.add_development_dependency "mysql2"
  spec.add_development_dependency "pg"
  spec.add_development_dependency "sqlite3"
  spec.add_development_dependency "rubocop-rails-omakase"
  spec.add_development_dependency "rdoc"
  spec.add_development_dependency "logger"

  if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.2")
    spec.add_development_dependency "zeitwerk", "2.6.0"
  end
end
