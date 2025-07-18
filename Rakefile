# frozen_string_literal: true

require "bundler/setup"

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

load "rails/tasks/statistics.rake"

require "bundler/gem_tasks"
require "rake/tasklib"

class TestHelpers < Rake::TaskLib
  def initialize(databases)
    @databases = databases
    define
  end

  def define
    desc "Run tests for all databases (mysql, postgres, sqlite)"
    task :test do
      @databases.each { |database| run_test_for_database(database) }
    end

    namespace :test do
      @databases.each do |database|
        desc "Run tests for #{database} database"
        task database do
          run_test_for_database(database)
        end
      end
    end
  end

  private

  def run_test_for_database(database)
    sh("TARGET_DB=#{database} bin/setup")
    sh("TARGET_DB=#{database} bin/rails test")
  end
end

TestHelpers.new(%w[ mysql postgres sqlite ])
