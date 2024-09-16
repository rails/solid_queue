# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
require "rails/test_help"
require "debug"
require "mocha/minitest"

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_path=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = ActiveSupport::TestCase.fixture_paths.first + "/files"
  ActiveSupport::TestCase.fixtures :all
end

module BlockLogDeviceTimeoutExceptions
  def write(...)
    # Prevents Timeout exceptions from occurring during log writing, where they will be swallowed
    # See https://bugs.ruby-lang.org/issues/9115
    Thread.handle_interrupt(Timeout::Error => :never, Timeout::ExitException => :never) { super }
  end
end

Logger::LogDevice.prepend(BlockLogDeviceTimeoutExceptions)

class ActiveSupport::TestCase
  include ProcessesTestHelper, JobsTestHelper

  teardown do
    JobBuffer.clear

    if SolidQueue.supervisor_pidfile && File.exist?(SolidQueue.supervisor_pidfile)
      File.delete(SolidQueue.supervisor_pidfile)
    end

    unless self.class.use_transactional_tests
      SolidQueue::Job.destroy_all
      SolidQueue::Process.destroy_all
      SolidQueue::Semaphore.delete_all
      SolidQueue::RecurringTask.delete_all
      JobResult.delete_all
    end
  end

  private
    def wait_while_with_timeout(timeout, &block)
      wait_while_with_timeout!(timeout, &block)
    rescue Timeout::Error
    end

    def wait_while_with_timeout!(timeout, &block)
      Timeout.timeout(timeout) do
        skip_active_record_query_cache do
          while block.call
            sleep 0.05
          end
        end
      end
    end

    # Allow skipping AR query cache, necessary when running test code in multiple
    # forks. The queries done in the test might be cached and if we don't perform
    # any non-SELECT queries after previous SELECT queries were cached on the connection
    # used in the test, the cache will still apply, even though the data returned
    # by the cached queries might have been updated, created or deleted in the forked
    # processes.
    def skip_active_record_query_cache(&block)
      SolidQueue::Record.uncached(&block)
    end
end
