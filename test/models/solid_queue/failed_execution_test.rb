require "test_helper"

class SolidQueue::FailedExecutionTest < ActiveSupport::TestCase
  setup do
    @worker = SolidQueue::Worker.new(queues: "background")
    @worker.mode = :inline
  end

  test "run job that fails" do
    RaisingJob.perform_later(ExpectedTestError, "A")
    @worker.start

    assert_equal 1, SolidQueue::FailedExecution.count
    assert SolidQueue::Job.last.failed?
  end

  test "run job that fails with a SystemStackError (stack level too deep)" do
    InfiniteRecursionJob.perform_later
    @worker.start

    assert_equal 1, SolidQueue::FailedExecution.count
    assert SolidQueue::Job.last.failed?
    assert_equal "stack level too deep", SolidQueue::FailedExecution.last.message
  end

  test "run job that fails with an error message larger than the error column" do
    # 70KB doesn't fit in MySQL's TEXT; other adapters have no limit and store it as is
    LargeErrorMessageJob.perform_later(70_000)
    @worker.start

    assert_equal 1, SolidQueue::FailedExecution.count
    assert SolidQueue::Job.last.failed?
    assert_fits_error_column SolidQueue::FailedExecution.last
  end

  test "truncate backtrace to fit the error column" do
    with_error_column_limit(1_000) do
      execution = fail_job_with ExpectedTestError.new("boom"), backtrace: Array.new(100) { |i| "app/models/thing.rb:#{i}:in 'do_it'" }

      assert_fits_error_column execution, limit: 1_000
      assert_equal "boom", execution.message
      assert_operator execution.backtrace.size, :>, 0
      assert_operator execution.backtrace.size, :<, 100
      assert_equal "app/models/thing.rb:0:in 'do_it'", execution.backtrace.first
    end
  end

  test "truncate message when it doesn't fit the error column by itself" do
    with_error_column_limit(1_000) do
      execution = fail_job_with ExpectedTestError.new("x" * 5_000), backtrace: [ "app/models/thing.rb:1:in 'do_it'" ]

      assert_fits_error_column execution, limit: 1_000
      assert_equal [], execution.backtrace
      assert execution.message.start_with?("xxx")
      assert execution.message.end_with?("... (truncated)")
    end
  end

  test "account for JSON escaping when fitting the error column" do
    with_error_column_limit(1_000) do
      # Quotes take two bytes once escaped, and HTML characters up to six
      execution = fail_job_with ExpectedTestError.new("\"<>&" * 200), backtrace: [ "app/models/thing.rb:1:in 'do_it'" ]

      assert_fits_error_column execution, limit: 1_000
    end
  end

  test "fit errors without a backtrace into the error column" do
    with_error_column_limit(1_000) do
      execution = fail_job_with ExpectedTestError.new("x" * 5_000), backtrace: nil

      assert_fits_error_column execution, limit: 1_000
      assert_nil execution.backtrace
    end
  end

  test "keep errors that fit in the error column intact" do
    backtrace = Array.new(5) { |i| "app/models/thing.rb:#{i}:in 'do_it'" }

    with_error_column_limit(1_000) do
      execution = fail_job_with ExpectedTestError.new("boom"), backtrace: backtrace

      assert_equal "boom", execution.message
      assert_equal backtrace, execution.backtrace
    end
  end

  test "retry failed job" do
    RaisingJob.perform_later(ExpectedTestError, "A")
    @worker.start

    assert_difference -> { SolidQueue::FailedExecution.count }, -1 do
      assert_difference -> { SolidQueue::ReadyExecution.count }, +1 do
        SolidQueue::FailedExecution.last.retry
      end
    end
  end

  test "retry failed jobs in bulk" do
    1.upto(5) { |i| RaisingJob.perform_later(ExpectedTestError, i) }
    1.upto(3) { |i| AddToBufferJob.perform_later(i) }

    @worker.start

    assert_difference -> { SolidQueue::FailedExecution.count }, -5 do
      assert_difference -> { SolidQueue::ReadyExecution.count }, +5 do
        SolidQueue::FailedExecution.retry_all(SolidQueue::Job.all)
      end
    end
  end

  private
    def with_error_column_limit(limit)
      SolidQueue::FailedExecution.any_instance.stubs(:error_column_limit).returns(limit)
      yield
    end

    def fail_job_with(exception, backtrace:)
      exception.set_backtrace(backtrace) if backtrace
      job = SolidQueue::Job.find_by!(active_job_id: AddToBufferJob.perform_later(1).job_id)

      job.failed_with(exception)
      job.reload.failed_execution
    end

    def assert_fits_error_column(execution, limit: execution.send(:error_column_limit))
      if limit
        stored_error = execution.class.connection.select_value(execution.class.where(id: execution.id).select(:error).to_sql)
        assert_operator stored_error.bytesize, :<=, limit
      end
    end
end
