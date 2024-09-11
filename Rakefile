# frozen_string_literal: true

require "bundler/setup"

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

load "rails/tasks/statistics.rake"

require "bundler/gem_tasks"

def databases
  %w[ mysql postgres sqlite ]
end

task :test do
  databases.each do |database|
    sh("TARGET_DB=#{database} bin/setup")
    sh("TARGET_DB=#{database} bin/rails test")
  end
end
