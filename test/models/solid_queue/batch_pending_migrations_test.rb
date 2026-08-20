# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/generators/solid_queue/update/templates/db/add_batches_to_solid_queue"

class BatchPendingMigrationsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # Recreate an app that hasn't run the optional batches migration by
  # reverting the actual migration that ships with the update generator,
  # which also proves it's reversible and matches the base schema.
  setup do
    migrate(:down)
  end

  teardown do
    migrate(:up)
    destroy_records
  end

  test "the batches schema counts as pending migrations" do
    assert_not SolidQueue::Batch.migrated?
  end

  test "starting a batch raises" do
    assert_raises SolidQueue::Batch::PendingMigrations do
      SolidQueue::Batch.enqueue { AddToBufferJob.perform_later("hey") }
    end
  end

  test "jobs enqueue, finish and get destroyed without batch bookkeeping" do
    active_job = AddToBufferJob.perform_later("hey")
    job = SolidQueue::Job.find_by!(active_job_id: active_job.job_id)

    job.finished!
    assert job.reload.finished?

    job.destroy!
    assert_not SolidQueue::Job.exists?(job.id)
  end

  test "jobs enqueue in bulk" do
    assert_difference -> { SolidQueue::Job.count }, +2 do
      ActiveJob.perform_all_later([ AddToBufferJob.new("hey"), AddToBufferJob.new("ho") ])
    end
  end

  test "jobs fail" do
    active_job = AddToBufferJob.perform_later("hey")
    job = SolidQueue::Job.find_by!(active_job_id: active_job.job_id)

    job.failed_with(ExpectedTestError.new("boom"))
    assert job.reload.failed_execution.present?
  end

  private
    def migrate(direction)
      ActiveRecord::Migration.suppress_messages do
        SolidQueue::Record.connection_pool.with_connection do |connection|
          AddBatchesToSolidQueue.new.exec_migration(connection, direction)
        end
      end

      SolidQueue::Job.reset_column_information
      SolidQueue::Batch.instance_variable_set(:@migrated, nil)

      # Changing the jobs table's shape invalidates cached prepared statements
      # whose SQL text didn't change (like SELECT "solid_queue_jobs".*), which
      # PostgreSQL rejects with PreparedStatementCacheExpired. Drop the pooled
      # connections so every test starts with a fresh statement cache.
      SolidQueue::Record.connection_pool.disconnect!
    end
end
