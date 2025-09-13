# Solid Queue Codebase Analysis

Co-authored-by: Mikael Henriksson <mikael@mhenrixon.com>

## Project Overview

Solid Queue is a database-backed queuing backend for Active Job in Ruby on Rails. It's designed as a modern, performant alternative to Redis-based solutions, leveraging SQL databases for job storage and processing.

### Key Characteristics
- **Version**: Currently in development on `batch-poc` branch
- **Ruby Version**: >= 3.1.6
- **Rails Version**: >= 7.2
- **Database Support**: MySQL 8+, PostgreSQL 9.5+, SQLite
- **License**: MIT

## Architecture Overview

### Core Components

1. **Workers**: Process jobs from queues
   - Multi-threaded execution using thread pools
   - Configurable polling intervals and batch sizes
   - Queue prioritization support

2. **Dispatchers**: Move scheduled jobs to ready state
   - Handle future-scheduled jobs
   - Manage concurrency controls
   - Perform maintenance tasks

3. **Scheduler**: Manages recurring tasks
   - Cron-like job scheduling
   - Supports job classes and eval commands

4. **Supervisor**: Orchestrates all processes
   - Process lifecycle management
   - Signal handling (TERM, INT, QUIT)
   - Heartbeat monitoring

## Current Development Focus: Batch Processing

The `batch-poc` branch implements job batching functionality, allowing:
- Grouping related jobs together
- Tracking collective progress
- Triggering callbacks on batch completion/failure
- Nested batch support with parent-child relationships
- Dynamic job addition within running batches

### Batch Implementation Architecture

#### Core Components

**SolidQueue::Batch** (app/models/solid_queue/batch.rb)
- Primary ActiveRecord model for batch persistence
- Manages batch context using `ActiveSupport::IsolatedExecutionState`
- Handles batch lifecycle and job enqueueing
- Tracks: `total_jobs`, `pending_jobs`, `completed_jobs`, `failed_jobs`
- Manages callback execution and status transitions (pending → processing → completed/failed)
- Handles parent-child batch relationships via `parent_batch_id`
- Serializes callback jobs as JSON for later execution
- Key instance methods: `enqueue`, `check_completion!`, `execute_callbacks`
- Key class methods: `enqueue`, `wrap_in_batch_context`, `current_batch_id`
- Automatically enqueues EmptyJob for empty batches to ensure callbacks fire
- Enqueues BatchMonitorJob for completion monitoring

**SolidQueue::Batch::Trackable** (app/models/solid_queue/batch/trackable.rb)
- Concern that provides status tracking and query scopes
- Scopes: `pending`, `processing`, `completed`, `failed`, `finished`, `unfinished`
- Helper methods: `finished?`, `processing?`, `pending?`, `progress_percentage`
- Calculates progress based on completed and failed jobs

**SolidQueue::BatchExecution** (app/models/solid_queue/batch_execution.rb)
- Lightweight tracking record that exists only while a job is pending
- Deleted atomically when job completes to trigger counter updates
- Presence indicates job hasn't been processed yet
- Key class methods:
  - `create_all_from_jobs`: Bulk creates executions and updates batch counters
  - `process_job_completion`: Handles atomic deletion and counter updates
- Uses database-specific upsert strategies for atomic counter increments

**SolidQueue::Job::Batchable** (app/models/solid_queue/job/batchable.rb)
- Concern mixed into Job model for batch support
- Creates BatchExecution records after job creation
- Tracks job completion via `after_update` callback
- Fires when `finished_at` is set (jobs being retried, not final failures)
- Handles batch progress updates when jobs complete

**SolidQueue::Execution::Batchable** (app/models/solid_queue/execution/batchable.rb)
- Concern mixed into Execution model for batch support
- Tracks final job failures via `after_create` callback on FailedExecution
- Only fires when job exhausts all retries
- Updates batch failure counter for permanently failed jobs

**ActiveJob::BatchId** (lib/active_job/batch_id.rb)
- ActiveJob extension for batch context
- Auto-assigns batch_id from context during job initialization
- Serializes/deserializes batch_id with job data
- Provides `batch` helper method to access current batch
- Only activates for SolidQueue adapter

**SolidQueue::Batch::CleanupJob** (app/jobs/solid_queue/batch/cleanup_job.rb)
- Internal job for cleaning up finished jobs in a batch
- Respects `preserve_finished_jobs` configuration
- Automatically enqueued after batch completion
- Discards on RecordNotFound to handle already-deleted batches gracefully

**SolidQueue::Batch::EmptyJob** (app/jobs/solid_queue/batch/empty_job.rb)
- Ensures batch callbacks fire even when no jobs are enqueued
- Does nothing in its perform method - exists solely to trigger completion
- Enables patterns where jobs are conditionally enqueued

**SolidQueue::BatchMonitorJob** (app/jobs/solid_queue/batch_monitor_job.rb)
- Monitors batch completion status with a 1-second polling interval
- Checks for completion when all child batches are finished and pending_jobs is 0
- Re-enqueues itself on error with a 30-second delay
- Automatically stops monitoring when batch is finished

#### Batch Lifecycle

1. **Creation Phase**:
   ```ruby
   batch = SolidQueue::Batch.enqueue(on_success: SuccessJob) do |batch|
     MyJob.perform_later(arg1)
     AnotherJob.perform_later(arg2)
   end
   ```
   - Creates UUID-identified batch record
   - Sets batch context using `ActiveSupport::IsolatedExecutionState`
   - Jobs automatically pick up batch_id from context
   - Batch persisted before jobs are enqueued
   - Parent batch relationship established if nested

2. **Job Enqueuing**:
   - ActiveJob::BatchId mixin captures batch_id during job initialization
   - Jobs created with batch_id foreign key
   - BatchExecution records created via `after_create` callback
   - Batch counters updated atomically using database-specific upserts
   - Total and pending job counts incremented together
   - BatchMonitorJob automatically enqueued to monitor completion

3. **Execution Phase**:
   - Jobs processed normally by workers
   - Job::Batchable `after_update` callback fires when `finished_at` is set
   - For retrying jobs: marked as finished, batch gets "completed" update
   - For final failures: FailedExecution created, triggers Execution::Batchable callback
   - BatchExecution.process_job_completion handles atomic counter updates

4. **Progress Tracking**:
   - BatchExecution deletion happens in transaction with counter updates
   - Atomic SQL: `pending_jobs = pending_jobs - 1, completed_jobs = completed_jobs + 1`
   - No locking needed for counter updates (atomic SQL operations)
   - Status changes from "pending" to "processing" on first job completion
   - Real-time progress via `progress_percentage` method

5. **Completion Detection**:
   - `check_completion!` called after each job finishes
   - Also monitored by BatchMonitorJob with 1-second polling
   - Uses pessimistic locking to prevent race conditions
   - Checks: `pending_jobs == 0` AND no unfinished child batches
   - Determines final status: "completed" if `failed_jobs == 0`, otherwise "failed"
   - Sets `finished_at` timestamp and updates status
   - Status transitions from "pending" to "processing" on first job completion

6. **Callback Execution**:
   - Callbacks deserialized and enqueued as regular jobs
   - Batch passed as first argument to callback job
   - Execution order: on_failure/on_success, then on_finish
   - Parent batch completion checked after callbacks
   - CleanupJob enqueued if jobs shouldn't be preserved

#### Batch Callbacks

**Callback Types:**
- `on_finish`: Always fires when batch completes (success or failure)
- `on_success`: Fires only when all jobs succeed (failed_jobs == 0)
- `on_failure`: Fires on first job failure after all retries exhausted

**Callback Execution:**
- Callbacks are ActiveJob instances serialized in the database
- Batch passed as first argument: `perform(batch, *original_args)`
- Executed asynchronously after batch completion
- Support for callback chaining in nested batches

#### Special Features

**Empty Batch Handling**:
- EmptyJob ensures callbacks fire even with no jobs
- Allows for conditional job enqueueing patterns
- Automatically enqueued when batch.total_jobs == 0 after enqueue block

**Dynamic Job Addition**:
```ruby
class MyJob < ApplicationJob
  def perform
    batch.enqueue do  # Add more jobs to current batch
      AnotherJob.perform_later
    end
  end
end
```

**Nested Batches**:
- Full parent-child relationship tracking
- Children must complete before parent can complete
- Callbacks execute from innermost to outermost

**Transaction Safety**:
- Full support for `enqueue_after_transaction_commit`
- Handles both synchronous and asynchronous enqueueing modes
- Prevents partial batch creation on rollback

**Cleanup**:
- CleanupJob removes finished jobs when `preserve_finished_jobs` is false
- Maintains batch records for audit trail

#### Database Schema

**solid_queue_batches table:**
- `batch_id`: UUID identifier (unique index)
- `parent_batch_id`: For nested batches (indexed)
- `status`: pending, processing, completed, failed (default: "pending")
- `total_jobs`: Total number of jobs in batch (default: 0)
- `pending_jobs`: Jobs not yet completed (default: 0)
- `completed_jobs`: Successfully completed jobs (default: 0)
- `failed_jobs`: Permanently failed jobs (default: 0)
- `on_finish`: Serialized ActiveJob for finish callback (TEXT)
- `on_success`: Serialized ActiveJob for success callback (TEXT)
- `on_failure`: Serialized ActiveJob for failure callback (TEXT)
- `metadata`: JSON field for custom data (TEXT)
- `finished_at`: Completion timestamp
- `created_at`, `updated_at`: Rails timestamps

**solid_queue_batch_executions table:**
- `job_id`: Foreign key to jobs table (unique index)
- `batch_id`: UUID reference to batch (STRING)
- `created_at`: Record creation timestamp
- Acts as presence indicator - deleted when job completes

**solid_queue_jobs table additions:**
- `batch_id`: UUID reference to batch (STRING, indexed)

## Development Approach

### Database Schema Management
**IMPORTANT**: This project uses direct schema files (`db/queue_schema.rb`) rather than Rails migrations during development. Changes to the database structure should be made directly in:
- `lib/generators/solid_queue/install/templates/db/queue_schema.rb` - Template schema
- `test/dummy/db/queue_schema.rb` - Test database schema

The schema is loaded fresh for tests, so schema changes can be made directly without migration files during development.

## Directory Structure

```
solid_queue/
   app/
      jobs/              # Internal job implementations
         solid_queue/
             batch_update_job.rb
             recurring_job.rb
      models/            # Core ActiveRecord models
          solid_queue/
              job.rb     # Main job model
              job_batch.rb # Batch tracking
              execution.rb family (claimed, ready, failed, etc.)
              process.rb # Worker/dispatcher processes
   lib/
      active_job/        # ActiveJob integration
         job_batch_id.rb
         queue_adapters/solid_queue_adapter.rb
      solid_queue/       # Core library code
         batch.rb       # Batch implementation
         worker.rb      # Worker implementation
         dispatcher.rb  # Dispatcher implementation
         supervisor.rb  # Process supervisor
      generators/        # Rails generator for installation
   test/
      integration/       # Integration tests
         batch_lifecycle_test.rb # Batch-specific tests
      models/           # Model tests
      unit/             # Unit tests
   config/
       routes.rb         # Engine routes (if any)
```

## Key Design Patterns

### 1. Polling with FOR UPDATE SKIP LOCKED
- Prevents lock contention between workers
- Ensures efficient job claiming
- Falls back gracefully on older databases

### 2. Semaphore-based Concurrency Control
- Limits concurrent executions per key
- Supports blocking and discarding strategies
- Configurable duration limits

### 3. Transactional Job Enqueueing
- Jobs and batch records created atomically
- Support for `enqueue_after_transaction_commit`
- Handles bulk enqueuing efficiently

### 4. Process Heartbeats
- Regular heartbeat updates from all processes
- Automatic cleanup of dead processes
- Configurable thresholds

## Testing Approach

- **73 test files** covering unit, integration, and model tests
- Test dummy Rails application in `test/dummy/`
- Custom test helpers for:
  - Process lifecycle testing
  - Job execution verification
  - Configuration testing
- Uses fixtures for test data

## Configuration Files

### Primary Configuration
- `config/queue.yml`: Worker and dispatcher configuration
- `config/recurring.yml`: Scheduled job definitions
- Database config requires separate `queue` database connection

### Important Settings
- `process_heartbeat_interval`: Default 60 seconds
- `process_alive_threshold`: Default 5 minutes
- `shutdown_timeout`: Default 5 seconds
- `preserve_finished_jobs`: Default true
- `clear_finished_jobs_after`: Default 1 day

## Development Workflow

### Current Git Status
- Branch: `batch-poc`
- Modified files indicate active batch development
- Tests being added/modified for batch functionality

### Key Modified Files
- `app/models/solid_queue/job/batchable.rb`: Job batch integration
- `app/models/solid_queue/execution/batchable.rb`: Execution batch handling
- `lib/solid_queue/batch.rb`: Core batch logic
- `test/integration/batch_lifecycle_test.rb`: Batch testing

## Performance Considerations

1. **Database Indexing**: Critical for polling performance
   - Index on `(queue_name, priority, job_id)`
   - Covering indexes for skip locked queries

2. **Batch Overhead**: Batching adds transactional overhead
   - Avoid mixing with bulk enqueuing
   - Consider impact on concurrency controls

3. **Thread Pool Sizing**: 
   - Should be less than database connection pool - 2
   - Account for polling and heartbeat connections

## ActiveJob Layer: Understanding the Division of Responsibilities

Solid Queue is intentionally designed as a **backend adapter** for ActiveJob, not a complete job processing framework. This architectural decision means many critical features are handled by ActiveJob itself, not Solid Queue. Understanding this layering is crucial for working with the codebase.

### Features Handled by ActiveJob (NOT in Solid Queue)

1. **Retry Logic** (`retry_on`)
   - ActiveJob manages retry attempts, backoff strategies, and max attempts
   - Solid Queue only stores failed executions for manual intervention
   - No retry mechanism exists in Solid Queue itself

2. **Error Handling** (`discard_on`, `rescue_from`)
   - ActiveJob decides whether to retry, discard, or handle errors
   - Solid Queue just captures and stores the error information
   - Custom error handling logic lives in job classes, not the queue

3. **Callbacks** (`before_enqueue`, `after_perform`, etc.)
   - All job lifecycle callbacks are ActiveJob features
   - Solid Queue doesn't know about or manage these callbacks
   - Exception: Batch callbacks are Solid Queue-specific

4. **Serialization/Deserialization**
   - ActiveJob handles argument serialization (GlobalID, etc.)
   - Solid Queue stores the serialized job data as JSON
   - Complex argument types are ActiveJob's responsibility

5. **Job Configuration**
   - `queue_as`, `priority`, and other DSL methods are ActiveJob
   - Solid Queue reads these values after ActiveJob sets them
   - Job class inheritance and configuration is pure ActiveJob

6. **Timeouts and Deadlines**
   - No built-in job timeout mechanism in Solid Queue
   - Must be implemented at the job level using ActiveJob patterns
   - Process-level timeouts handled via signals only

### Features Solid Queue DOES Provide

1. **Storage and Retrieval**
   - Database schema for jobs and executions
   - Efficient polling with `FOR UPDATE SKIP LOCKED`
   - Transaction-safe job claiming

2. **Process Management**
   - Worker processes with thread pools
   - Dispatcher for scheduled jobs
   - Supervisor for process lifecycle

3. **Concurrency Controls** (Extended ActiveJob)
   - Semaphore-based limiting
   - Blocking/discarding on conflicts
   - Duration-based expiry

4. **Batch Processing** (Extended ActiveJob)
   - Job grouping and tracking
   - Batch-specific callbacks
   - Progress monitoring

5. **Recurring Jobs**
   - Cron-like scheduling
   - Separate from ActiveJob's scheduling

### The Adapter Pattern

The `SolidQueueAdapter` is minimal by design:
```ruby
class SolidQueueAdapter
  def enqueue(active_job)
    SolidQueue::Job.enqueue(active_job)
  end
  
  def enqueue_at(active_job, timestamp)
    SolidQueue::Job.enqueue(active_job, scheduled_at: Time.at(timestamp))
  end
end
```

This thin adapter means:
- Solid Queue doesn't parse job classes
- It doesn't understand job arguments beyond storage
- It doesn't execute business logic, only job invocation

### Implications for Development

When working with Solid Queue:

1. **Don't look for retry logic here** - It's in ActiveJob
2. **Don't implement job-level features** - Use ActiveJob patterns
3. **Focus on infrastructure** - Storage, retrieval, process management
4. **Extend via ActiveJob** - Custom job classes, not queue modifications
5. **Batch features are special** - One of the few job-level features in Solid Queue

### Error Flow Example

1. Job raises exception during `perform`
2. ActiveJob's `retry_on` catches it
3. ActiveJob decides: retry now, retry later, or discard
4. If retrying later: ActiveJob calls `enqueue_at` on adapter
5. Solid Queue stores the job with new scheduled time
6. If final failure: Solid Queue creates `failed_execution` record
7. Manual intervention needed via `failed_execution.retry`

### CRITICAL: Job Retry Behavior in Solid Queue

**Each retry attempt creates a new job with a new job_id but same active_job_id**

When a job fails and will be retried:
1. The current job is marked as `finished` (finished_at is set)
2. A new job is created for the retry with a new job_id
3. The jobs share the same active_job_id

When a job exhausts all retries (final failure):
1. The final job is NOT marked as finished (finished_at remains nil)
2. A FailedExecution record is created
3. No new job is created

**Example with 3 retry attempts:**
- Job 1 (id: 100) fails → marked as finished → Job 2 created
- Job 2 (id: 101) fails → marked as finished → Job 3 created  
- Job 3 (id: 102) fails → NOT marked as finished → FailedExecution created

This means:
- Jobs that are retried DO have finished_at set
- Jobs with FailedExecutions do NOT have finished_at set
- The Job::Batchable callback fires for jobs being retried (they're "finished")
- The Execution::Batchable callback fires for final failures (FailedExecution created)

This separation keeps Solid Queue focused on being a robust, database-backed storage and execution engine while ActiveJob handles the higher-level job processing semantics.

## Integration Points

### Rails Integration
- Engine-based architecture
- Automatic configuration in Rails 8
- Generator for easy setup

### Database Adapters
- Adapter-specific optimizations
- Automatic skip locked detection
- Connection pool management

## Security Considerations

- No secrets/credentials in job arguments
- Careful with eval in recurring tasks
- Database permissions for queue database

## Common Patterns for Extension

### Adding New Job Types
1. Inherit from `ApplicationJob`
2. Use batch context for batch jobs
3. Implement proper error handling

### Custom Callbacks
1. Use lifecycle hooks for process events
2. Implement batch callbacks for completion logic
3. Consider transactional boundaries

### Performance Monitoring
1. Hook into instrumentation API
2. Monitor heartbeat intervals
3. Track queue depths and processing times

## Debugging Tips

1. **Check heartbeats**: Ensure processes are alive
2. **Review failed_executions**: Inspect error details
3. **Monitor semaphores**: Check for concurrency blocks
4. **Batch status**: Use `JobBatch` model to track progress
5. **Enable query logs**: Set `silence_polling: false`

## Known Limitations

1. Phased restarts not supported with Puma plugin
2. Queue order not preserved in concurrency unblocking
3. Batch callbacks execute asynchronously
4. No automatic retry mechanism (relies on ActiveJob)

## Future Considerations

- Batch lifecycle improvements in progress
- Potential for distributed locking mechanisms
- Enhanced monitoring and metrics
- Dashboard UI integration improvements

## Code Style and Conventions

### Model Structure
- **Base Class**: All models inherit from `SolidQueue::Record` (not directly from `ActiveRecord::Base`)
- **Concerns**: Extract shared behavior into concerns under `app/models/solid_queue/{model}/`
- **Associations**: Define clear relationships with foreign keys and dependent options
- **Scopes**: Use descriptive names, chain simple scopes for complex queries

### Naming Conventions
```ruby
# Classes
class SolidQueue::ReadyExecution < Execution  # Descriptive, namespaced

# Methods
def dispatch_batch                # Action verb for operations
def finished?                      # Predicate with ?
def finish!                        # Bang for state changes
def with_lock                      # Preposition for context methods
def after_commit_on_finish         # Lifecycle callbacks clearly named

# Constants
DEFAULT_BATCH_SIZE = 500           # SCREAMING_SNAKE_CASE
STATUSES = %w[ pending processing completed failed ]  # Arrays for enums
```

### Database Operations

#### Transaction Patterns
```ruby
# Always wrap multi-step operations
transaction do
  job = create!(job_attributes)
  job.prepare_for_execution
  job
end

# Use with_lock for pessimistic locking
batch_record.with_lock do
  batch_record.update!(pending_jobs: batch_record.pending_jobs - 1)
  batch_record.check_completion!
end
```

#### Bulk Operations
```ruby
# Prefer insert_all for bulk creates
insert_all(execution_rows, returning: %w[ id job_id ])

# Use update_all for batch updates
where(id: job_ids).update_all(finished_at: Time.current)

# Chain scopes for complex queries
ready.by_priority.limit(batch_size)
```

#### SQL Safety
```ruby
# Parameterized queries
where("scheduled_at <= ?", Time.current)

# Arel for complex SQL
lock(Arel.sql("FOR UPDATE SKIP LOCKED"))

# Avoid string interpolation
# BAD: where("status = '#{status}'")
# GOOD: where(status: status)
```

### Concern Organization

```ruby
module SolidQueue
  module Job
    module Batchable
      extend ActiveSupport::Concern

      included do
        # Associations
        belongs_to :batch_record, optional: true
        
        # Callbacks
        after_update :track_batch_progress, if: :batch_id?
        
        # Scopes
        scope :in_batch, ->(batch_id) { where(batch_id: batch_id) }
      end

      class_methods do
        # Class-level functionality
      end

      # Instance methods grouped by purpose
      private
        def track_batch_progress
          # Implementation
        end
    end
  end
end
```

### Callback Patterns

```ruby
# Use conditional callbacks
after_create :dispatch, if: :ready?
after_destroy :unblock_next, if: -> { concurrency_limited? && ready? }

# Separate callback methods
private
  def dispatch
    ReadyExecution.create_from_job(self)
  end
```

### Error Handling

```ruby
# Custom exceptions with context
class BatchCompletionError < StandardError
  attr_reader :batch_id
  
  def initialize(batch_id, message)
    @batch_id = batch_id
    super("Batch #{batch_id}: #{message}")
  end
end

# Wrap and re-raise with context
rescue ActiveRecord::RecordNotUnique => e
  raise EnqueueError.new("Duplicate job: #{e.message}").tap { |error|
    error.set_backtrace(e.backtrace)
  }
end

# Silent rescue for non-critical operations
def optional_cleanup
  # cleanup code
rescue => e
  Rails.logger.error "[SolidQueue] Cleanup failed: #{e.message}"
end
```

### Instrumentation

```ruby
# Always instrument important operations
SolidQueue.instrument(:batch_update, batch_id: batch_id) do |payload|
  result = perform_update
  payload[:jobs_updated] = result.count
  result
end
```

### Testing Patterns

```ruby
# Use transactional tests sparingly
self.use_transactional_tests = false  # For integration tests

# Custom assertions
def assert_batch_completed(batch_id)
  batch = SolidQueue::BatchRecord.find(batch_id)
  assert_equal "completed", batch.status
  assert_equal 0, batch.pending_jobs
end

# Wait helpers for async operations
wait_for_jobs_to_finish_for(2.seconds)
```

### Key Principles

1. **Composition over Inheritance**: Use concerns for shared behavior
2. **Fail Fast**: Validate early, use bang methods for critical operations
3. **Idempotency**: Design operations to be safely retryable
4. **Instrumentation**: Measure everything important
5. **Clear Boundaries**: Models handle persistence, jobs handle business logic
6. **Defensive Coding**: Handle nil cases, use safe navigation (`&.`)
7. **Explicit over Implicit**: Clear method names over clever shortcuts
8. **Transaction Safety**: Always consider rollback scenarios
9. **Performance First**: Use bulk operations, avoid N+1 queries
10. **Rails Conventions**: Follow Rails patterns unless there's a good reason not to

### IMPORTANT

- Always utilize ActiveSupport::IsolatedExecutionState instead of Thread.current