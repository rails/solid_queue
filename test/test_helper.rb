# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [File.expand_path("../test/dummy/db/migrate", __dir__)]
require "rails/test_help"
require "debug"
require "mocha/minitest"

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_path=)
  ActiveSupport::TestCase.fixture_path = File.expand_path("fixtures", __dir__)
  ActionDispatch::IntegrationTest.fixture_path = ActiveSupport::TestCase.fixture_path
  ActiveSupport::TestCase.file_fixture_path = ActiveSupport::TestCase.fixture_path + "/files"
  ActiveSupport::TestCase.fixtures :all
end

class ActiveSupport::TestCase
  teardown do
    JobBuffer.clear
  end

  private
    def wait_for_jobs_to_finish_for(timeout = 10.seconds)
      Timeout.timeout(timeout) do
        while SolidQueue::Job.where(finished_at: nil).any? do
          sleep 0.25
        end
      end
    rescue Timeout::Error
    end
end
