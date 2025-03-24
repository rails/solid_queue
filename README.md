# Solid Queue

Solid Queue is a DB-based queuing backend for [Active Job](https://edgeguides.rubyonrails.org/active_job_basics.html), designed with simplicity and performance in mind.

Besides regular job enqueuing and processing, Solid Queue supports delayed jobs, concurrency controls, recurring jobs, pausing queues, numeric priorities per job, priorities by queue order, and bulk enqueuing (`enqueue_all` for Active Job's `perform_all_later`).

Solid Queue can be used with SQL databases such as MySQL, PostgreSQL or SQLite, and it leverages the `FOR UPDATE SKIP LOCKED` clause, if available, to avoid blocking and waiting on locks when polling jobs. It relies on Active Job for retries, discarding, error handling, serialization, or delays, and it's compatible with Ruby on Rails's multi-threading.

## Table of contents

- [Installation](#installation)
  - [Usage in development and other non-production environments](#usage-in-development-and-other-non-production-environments)
  - [Single database configuration](#single-database-configuration)
  - [Incremental adoption](#incremental-adoption)
  - [High performance requirements](#high-performance-requirements)
- [Configuration](#configuration)
  - [Workers, dispatchers and scheduler](#workers-dispatchers-and-scheduler)
  - [Queue order and priorities](#queue-order-and-priorities)
  - [Queues specification and performance](#queues-specification-and-performance)
  - [Threads, processes and signals](#threads-processes-and-signals)
  - [Database configuration](#database-configuration)
  - [Other configuration settings](#other-configuration-settings)
- [Lifecycle hooks](#lifecycle-hooks)
- [Errors when enqueuing](#errors-when-enqueuing)
- [Concurrency controls](#concurrency-controls)
- [Failed jobs and retries](#failed-jobs-and-retries)
  - [Error reporting on jobs](#error-reporting-on-jobs)
- [Puma plugin](#puma-plugin)
- [Jobs and transactional integrity](#jobs-and-transactional-integrity)
- [Recurring tasks](#recurring-tasks)
- [Inspiration](#inspiration)
- [License](#license)


## Installation

Solid Queue is configured by default in new Rails 8 applications. But if you're running an earlier version, you can add it manually following these steps:

1. `bundle add solid_queue`
2. `bin/rails solid_queue:install`

(Note: The minimum supported version of Rails is 7.1 and Ruby is 3.1.6.)

This will configure Solid Queue as the production Active Job backend, create the configuration files `config/queue.yml` and `config/recurring.yml`, and create the `db/queue_schema.rb`. It'll also create a `bin/jobs` executable wrapper that you can use to start Solid Queue.

Once you've done that, you will then have to add the configuration for the queue database in `config/database.yml`. If you're using SQLite, it'll look like this:

```yaml
production:
  primary:
    <<: *default
    database: storage/production.sqlite3
  queue:
    <<: *default
    database: storage/production_queue.sqlite3
    migrations_paths: db/queue_migrate
```

...or if you're using MySQL/PostgreSQL/Trilogy:

```yaml
production:
  primary: &primary_production
    <<: *default
    database: app_production
    username: app
    password: <%= ENV["APP_DATABASE_PASSWORD"] %>
  queue:
    <<: *primary_production
    database: app_production_queue
    migrations_paths: db/queue_migrate
```

Then run `db:prepare` in production to ensure the database is created and the schema is loaded.

Now you're ready to start processing jobs by running `bin/jobs` on the server that's doing the work. This will start processing jobs in all queues using the default configuration. See [below](#configuration) to learn more about configuring Solid Queue.

For small projects, you can run Solid Queue on the same machine as your webserver. When you're ready to scale, Solid Queue supports horizontal scaling out-of-the-box. You can run Solid Queue on a separate server from your webserver, or even run `bin/jobs` on multiple machines at the same time. Depending on the configuration, you can designate some machines to run only dispatchers or only workers. See the [configuration](#configuration) section for more details on this.

**Note**: future changes to the schema will come in the form of regular migrations.

### Usage in development and other non-production environments

Calling `bin/rails solid_queue:install` will automatically add `config.solid_queue.connects_to = { database: { writing: :queue } }` to `config/environments/production.rb`. In order to use Solid Queue in other environments (such as development or staging), you'll need to add a similar configuration(s).

For example, if you're using SQLite in development, update `database.yml` as follows:

```diff
development:
+ primary:
    <<: *default
    database: storage/development.sqlite3
+  queue:
+    <<: *default
+    database: storage/development_queue.sqlite3
+    migrations_paths: db/queue_migrate
```

Next, add the following to `development.rb`

```ruby
  # Use Solid Queue in Development.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }
```

Once you've added this, run `db:prepare` to create the Solid Queue database and load the schema.

Finally, in order for jobs to be processed, you'll need to have Solid Queue running. In Development, this can be done via [the Puma plugin](#puma-plugin) as well. In `puma.rb` update the following line:

```ruby
# You can either set the env var, or check for development
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"] || Rails.env.development?
```

You can also just use `bin/jobs`, but in this case you might want to [set a different logger for Solid Queue](#other-configuration-settings) because the default logger will log to `log/development.log` and you won't see anything when you run `bin/jobs`. For example:
```ruby
config.solid_queue.logger = ActiveSupport::Logger.new(STDOUT)
```

**Note about Action Cable**: If you use Action Cable (or anything dependent on Action Cable, such as Turbo Streams), you will also need to update it to use a database.

In `config/cable.yml`

```diff
development:
-  adapter: async
+ adapter: solid_cable
+  connects_to:
+    database:
+      writing: cable
+  polling_interval: 0.1.seconds
+  message_retention: 1.day
```

In `config/database.yml`

```diff
development:
  primary:
    <<: *default
    database: storage/development.sqlite3
+  cable:
+    <<: *default
+    database: storage/development_cable.sqlite3
+    migrations_paths: db/cable_migrate
```

### Single database configuration

Running Solid Queue in a separate database is recommended, but it's also possible to use one single database for both the app and the queue. Just follow these steps:

1. Copy the contents of `db/queue_schema.rb` into a normal migration and delete `db/queue_schema.rb`
2. Remove `config.solid_queue.connects_to` from `production.rb`
3. Migrate your database. You are ready to run `bin/jobs`

You won't have multiple databases, so `database.yml` doesn't need to have primary and queue database.

### Incremental adoption

If you're planning to adopt Solid Queue incrementally by switching one job at the time, you can do so by leaving the `config.active_job.queue_adapter` set to your old backend, and then set the `queue_adapter` directly in the jobs you're moving:

```ruby
# app/jobs/my_job.rb

class MyJob < ApplicationJob
  self.queue_adapter = :solid_queue
  # ...
end
```

### High performance requirements

Solid Queue was designed for the highest throughput when used with MySQL 8+ or PostgreSQL 9.5+, as they support `FOR UPDATE SKIP LOCKED`. You can use it with older versions, but in that case, you might run into lock waits if you run multiple workers for the same queue. You can also use it with SQLite on smaller applications.

## Configuration

### Workers, dispatchers and scheduler

We have several types of actors in Solid Queue:

- _Workers_ are in charge of picking jobs ready to run from queues and processing them. They work off the `solid_queue_ready_executions` table.
- _Dispatchers_ are in charge of selecting jobs scheduled to run in the future that are due and _dispatching_ them, which is simply moving them from the `solid_queue_scheduled_executions` table over to the `solid_queue_ready_executions` table so that workers can pick them up. On top of that, they do some maintenance work related to [concurrency controls](#concurrency-controls).
- The _scheduler_ manages [recurring tasks](#recurring-tasks), enqueuing jobs for them when they're due.
- The _supervisor_ runs workers and dispatchers according to the configuration, controls their heartbeats, and stops and starts them when needed.

Solid Queue's supervisor will fork a separate process for each supervised worker/dispatcher/scheduler.

By default, Solid Queue will try to find your configuration under `config/queue.yml`, but you can set a different path using the environment variable `SOLID_QUEUE_CONFIG` or by using the `-c/--config_file` option with `bin/jobs`, like this:

```
bin/jobs -c config/calendar.yml
```

This is what this configuration looks like:

```yml
production:
  dispatchers:
    - polling_interval: 1
      batch_size: 500
      concurrency_maintenance_interval: 300
  workers:
    - queues: "*"
      threads: 3
      polling_interval: 2
    - queues: [ real_time, background ]
      threads: 5
      polling_interval: 0.1
      processes: 3
```

Everything is optional. If no configuration at all is provided, Solid Queue will run with one dispatcher and one worker with default settings. If you want to run only dispatchers or workers, you just need to include that section alone in the configuration. For example, with the following configuration:

```yml
production:
  dispatchers:
    - polling_interval: 1
      batch_size: 500
      concurrency_maintenance_interval: 300
```
the supervisor will run 1 dispatcher and no workers.


Here's an overview of the different options:

- `polling_interval`: the time interval in seconds that workers and dispatchers will wait before checking for more jobs. This time defaults to `1` second for dispatchers and `0.1` seconds for workers.
- `batch_size`: the dispatcher will dispatch jobs in batches of this size. The default is 500.
- `concurrency_maintenance_interval`: the time interval in seconds that the dispatcher will wait before checking for blocked jobs that can be unblocked. Read more about [concurrency controls](#concurrency-controls) to learn more about this setting. It defaults to `600` seconds.
- `queues`: the list of queues that workers will pick jobs from. You can use `*` to indicate all queues (which is also the default and the behaviour you'll get if you omit this). You can provide a single queue, or a list of queues as an array. Jobs will be polled from those queues in order, so for example, with `[ real_time, background ]`, no jobs will be taken from `background` unless there aren't any more jobs waiting in `real_time`. You can also provide a prefix with a wildcard to match queues starting with a prefix. For example:

  ```yml
  staging:
    workers:
      - queues: staging*
        threads: 3
        polling_interval: 5

  ```

  This will create a worker fetching jobs from all queues starting with `staging`. The wildcard `*` is only allowed on its own or at the end of a queue name; you can't specify queue names such as `*_some_queue`. These will be ignored.

  Finally, you can combine prefixes with exact names, like `[ staging*, background ]`, and the behaviour with respect to order will be the same as with only exact names.

  Check the sections below on [how queue order behaves combined with priorities](#queue-order-and-priorities), and [how the way you specify the queues per worker might affect performance](#queues-specification-and-performance).

- `threads`: this is the max size of the thread pool that each worker will have to run jobs. Each worker will fetch this number of jobs from their queue(s), at most and will post them to the thread pool to be run. By default, this is `3`. Only workers have this setting.
It is recommended to set this value less than or equal to the queue database's connection pool size minus 2, as each worker thread uses one connection, and two additional connections are reserved for polling and heartbeat.
- `processes`: this is the number of worker processes that will be forked by the supervisor with the settings given. By default, this is `1`, just a single process. This setting is useful if you want to dedicate more than one CPU core to a queue or queues with the same configuration. Only workers have this setting.
- `concurrency_maintenance`: whether the dispatcher will perform the concurrency maintenance work. This is `true` by default, and it's useful if you don't use any [concurrency controls](#concurrency-controls) and want to disable it or if you run multiple dispatchers and want some of them to just dispatch jobs without doing anything else.


### Queue order and priorities

As mentioned above, if you specify a list of queues for a worker, these will be polled in the order given, such as for the list `real_time,background`, no jobs will be taken from `background` unless there aren't any more jobs waiting in `real_time`.

Active Job also supports positive integer priorities when enqueuing jobs. In Solid Queue, the smaller the value, the higher the priority. The default is `0`.

This is useful when you run jobs with different importance or urgency in the same queue. Within the same queue, jobs will be picked in order of priority, but in a list of queues, the queue order takes precedence, so in the previous example with `real_time,background`, jobs in the `real_time` queue will be picked before jobs in the `background` queue, even if those in the `background` queue have a higher priority (smaller value) set.

We recommend not mixing queue order with priorities but either choosing one or the other, as that will make job execution order more straightforward for you.

### Queues specification and performance

To keep polling performant and ensure a covering index is always used, Solid Queue only does two types of polling queries:
```sql
-- No filtering by queue
SELECT job_id
FROM solid_queue_ready_executions
ORDER BY priority ASC, job_id ASC
LIMIT ?
FOR UPDATE SKIP LOCKED;

-- Filtering by a single queue
SELECT job_id
FROM solid_queue_ready_executions
WHERE queue_name = ?
ORDER BY priority ASC, job_id ASC
LIMIT ?
FOR UPDATE SKIP LOCKED;
```

The first one (no filtering by queue) is used when you specify
```yml
queues: *
```
and there aren't any queues paused, as we want to target all queues.

In other cases, we need to have a list of queues to filter by, in order, because we can only filter by a single queue at a time to ensure we use an index to sort. This means that if you specify your queues as:
```yml
queues: beta*
```

we'll need to get a list of all existing queues matching that prefix first, with a query that would look like this:
```sql
SELECT DISTINCT(queue_name)
FROM solid_queue_ready_executions
WHERE queue_name LIKE 'beta%';
```

This type of `DISTINCT` query on a column that's the leftmost column in an index can be performed very fast in MySQL thanks to a technique called [Loose Index Scan](https://dev.mysql.com/doc/refman/8.0/en/group-by-optimization.html#loose-index-scan). PostgreSQL and SQLite, however, don't implement this technique, which means that if your `solid_queue_ready_executions` table is very big because your queues get very deep, this query will get slow. Normally your `solid_queue_ready_executions` table will be small, but it can happen.

Similarly to using prefixes, the same will happen if you have paused queues, because we need to get a list of all queues with a query like
```sql
SELECT DISTINCT(queue_name)
FROM solid_queue_ready_executions
```

and then remove the paused ones. Pausing in general should be something rare, used in special circumstances, and for a short period of time. If you don't want to process jobs from a queue anymore, the best way to do that is to remove it from your list of queues.

💡 To sum up, **if you want to ensure optimal performance on polling**, the best way to do that is to always specify exact names for them, and not have any queues paused.

Do this:

```yml
queues: [ background, backend ]
```

instead of this:
```yml
queues: back*
```


### Threads, processes and signals

Workers in Solid Queue use a thread pool to run work in multiple threads, configurable via the `threads` parameter above. Besides this, parallelism can be achieved via multiple processes on one machine (configurable via different workers or the `processes` parameter above) or by horizontal scaling.

The supervisor is in charge of managing these processes, and it responds to the following signals:
- `TERM`, `INT`: starts graceful termination. The supervisor will send a `TERM` signal to its supervised processes, and it'll wait up to `SolidQueue.shutdown_timeout` time until they're done. If any supervised processes are still around by then, it'll send a `QUIT` signal to them to indicate they must exit.
- `QUIT`: starts immediate termination. The supervisor will send a `QUIT` signal to its supervised processes, causing them to exit immediately.

When receiving a `QUIT` signal, if workers still have jobs in-flight, these will be returned to the queue when the processes are deregistered.

If processes have no chance of cleaning up before exiting (e.g. if someone pulls a cable somewhere), in-flight jobs might remain claimed by the processes executing them. Processes send heartbeats, and the supervisor checks and prunes processes with expired heartbeats. Jobs that were claimed by processes with an expired heartbeat will be marked as failed with a `SolidQueue::Processes::ProcessPrunedError`. You can configure both the frequency of heartbeats and the threshold to consider a process dead. See the section below for this.

In a similar way, if a worker is terminated in any other way not initiated by the above signals (e.g. a worker is sent a `KILL` signal), jobs in progress will be marked as failed so that they can be inspected, with a `SolidQueue::Processes::Process::ProcessExitError`. Sometimes a job in particular is responsible for this, for example, if it has a memory leak and you have a mechanism to kill processes over a certain memory threshold, so this will help identifying this kind of situation.


### Database configuration

You can configure the database used by Solid Queue via the `config.solid_queue.connects_to` option in the `config/application.rb` or `config/environments/production.rb` config files. By default, a single database is used for both writing and reading called `queue` to match the database configuration you set up during the install.

All the options available to Active Record for multiple databases can be used here.

### Other configuration settings

_Note_: The settings in this section should be set in your `config/application.rb` or your environment config like this: `config.solid_queue.silence_polling = true`

There are several settings that control how Solid Queue works that you can set as well:
- `logger`: the logger you want Solid Queue to use. Defaults to the app logger.
- `app_executor`: the [Rails executor](https://guides.rubyonrails.org/threading_and_code_execution.html#executor) used to wrap asynchronous operations, defaults to the app executor
- `on_thread_error`: custom lambda/Proc to call when there's an error within a Solid Queue thread that takes the exception raised as argument. Defaults to

  ```ruby
  -> (exception) { Rails.error.report(exception, handled: false) }
  ```

  **This is not used for errors raised within a job execution**. Errors happening in jobs are handled by Active Job's `retry_on` or `discard_on`, and ultimately will result in [failed jobs](#failed-jobs-and-retries). This is for errors happening within Solid Queue itself.

- `use_skip_locked`: whether to use `FOR UPDATE SKIP LOCKED` when performing locking reads. This will be automatically detected in the future, and for now, you'd only need to set this to `false` if your database doesn't support it. For MySQL, that'd be versions < 8, and for PostgreSQL, versions < 9.5. If you use SQLite, this has no effect, as writes are sequential.
- `process_heartbeat_interval`: the heartbeat interval that all processes will follow—defaults to 60 seconds.
- `process_alive_threshold`: how long to wait until a process is considered dead after its last heartbeat—defaults to 5 minutes.
- `shutdown_timeout`: time the supervisor will wait since it sent the `TERM` signal to its supervised processes before sending a `QUIT` version to them requesting immediate termination—defaults to 5 seconds.
- `silence_polling`: whether to silence Active Record logs emitted when polling for both workers and dispatchers—defaults to `true`.
- `supervisor_pidfile`: path to a pidfile that the supervisor will create when booting to prevent running more than one supervisor in the same host, or in case you want to use it for a health check. It's `nil` by default.
- `preserve_finished_jobs`: whether to keep finished jobs in the `solid_queue_jobs` table—defaults to `true`.
- `clear_finished_jobs_after`: period to keep finished jobs around, in case `preserve_finished_jobs` is true—defaults to 1 day. **Note:** Right now, there's no automatic cleanup of finished jobs. You'd need to do this by periodically invoking `SolidQueue::Job.clear_finished_in_batches`, which can be configured as [a recurring task](#recurring-tasks).
- `default_concurrency_control_period`: the value to be used as the default for the `duration` parameter in [concurrency controls](#concurrency-controls). It defaults to 3 minutes.


## Lifecycle hooks

In Solid queue, you can hook into two different points in the supervisor's life:
- `start`: after the supervisor has finished booting and right before it forks workers and dispatchers.
- `stop`: after receiving a signal (`TERM`, `INT` or `QUIT`) and right before starting graceful or immediate shutdown.

And into two different points in the worker's, dispatcher's and scheduler's life:
- `(worker|dispatcher|scheduler)_start`: after the worker/dispatcher/scheduler has finished booting and right before it starts the polling loop or loading the recurring schedule.
- `(worker|dispatcher|scheduler)_stop`: after receiving a signal (`TERM`, `INT` or `QUIT`) and right before starting graceful or immediate shutdown (which is just `exit!`).

Each of these hooks has an instance of the supervisor/worker/dispatcher/scheduler yielded to the block so that you may read its configuration for logging or metrics reporting purposes.

You can use the following methods with a block to do this:
```ruby
SolidQueue.on_start
SolidQueue.on_stop

SolidQueue.on_worker_start
SolidQueue.on_worker_stop

SolidQueue.on_dispatcher_start
SolidQueue.on_dispatcher_stop

SolidQueue.on_scheduler_start
SolidQueue.on_scheduler_stop
```

For example:
```ruby
SolidQueue.on_start do |supervisor|
  MyMetricsReporter.process_name = supervisor.name

  start_metrics_server
end

SolidQueue.on_stop do |_supervisor|
  stop_metrics_server
end

SolidQueue.on_worker_start do |worker|
  MyMetricsReporter.process_name = worker.name
  MyMetricsReporter.queues = worker.queues.join(',')
end
```

These can be called several times to add multiple hooks, but it needs to happen before Solid Queue is started. An initializer would be a good place to do this.


## Errors when enqueuing

Solid Queue will raise a `SolidQueue::Job::EnqueueError` for any Active Record errors that happen when enqueuing a job. The reason for not raising `ActiveJob::EnqueueError` is that this one gets handled by Active Job, causing `perform_later` to return `false` and set `job.enqueue_error`, yielding the job to a block that you need to pass to `perform_later`. This works very well for your own jobs, but makes failure very hard to handle for jobs enqueued by Rails or other gems, such as `Turbo::Streams::BroadcastJob` or `ActiveStorage::AnalyzeJob`, because you don't control the call to `perform_later` in that cases.

In the case of recurring tasks, if such error is raised when enqueuing the job corresponding to the task, it'll be handled and logged but it won't bubble up.

## Concurrency controls

Solid Queue extends Active Job with concurrency controls, that allows you to limit how many jobs of a certain type or with certain arguments can run at the same time. When limited in this way, jobs will be blocked from running, and they'll stay blocked until another job finishes and unblocks them, or after the set expiry time (concurrency limit's _duration_) elapses. Jobs are never discarded or lost, only blocked.

```ruby
class MyJob < ApplicationJob
  limits_concurrency to: max_concurrent_executions, key: ->(arg1, arg2, **) { ... }, duration: max_interval_to_guarantee_concurrency_limit, group: concurrency_group

  # ...
```
- `key` is the only required parameter, and it can be a symbol, a string or a proc that receives the job arguments as parameters and will be used to identify the jobs that need to be limited together. If the proc returns an Active Record record, the key will be built from its class name and `id`.
- `to` is `1` by default.
- `duration` is set to `SolidQueue.default_concurrency_control_period` by default, which itself defaults to `3 minutes`, but that you can configure as well.
- `group` is used to control the concurrency of different job classes together. It defaults to the job class name.

When a job includes these controls, we'll ensure that, at most, the number of jobs (indicated as `to`) that yield the same `key` will be performed concurrently, and this guarantee will last for `duration` for each job enqueued. Note that there's no guarantee about _the order of execution_, only about jobs being performed at the same time (overlapping).

The concurrency limits use the concept of semaphores when enqueuing, and work as follows: when a job is enqueued, we check if it specifies concurrency controls. If it does, we check the semaphore for the computed concurrency key. If the semaphore is open, we claim it and we set the job as _ready_. Ready means it can be picked up by workers for execution. When the job finishes executing (be it successfully or unsuccessfully, resulting in a failed execution), we signal the semaphore and try to unblock the next job with the same key, if any. Unblocking the next job doesn't mean running that job right away, but moving it from _blocked_ to _ready_. Since something can happen that prevents the first job from releasing the semaphore and unblocking the next job (for example, someone pulling a plug in the machine where the worker is running), we have the `duration` as a failsafe. Jobs that have been blocked for more than duration are candidates to be released, but only as many of them as the concurrency rules allow, as each one would need to go through the semaphore dance check. This means that the `duration` is not really about the job that's enqueued or being run, it's about the jobs that are blocked waiting. It's important to note that after one or more candidate jobs are unblocked (either because a job finishes or because `duration` expires and a semaphore is released), the `duration` timer for the still blocked jobs is reset. This happens indirectly via the expiration time of the semaphore, which is updated.


For example:
```ruby
class DeliverAnnouncementToContactJob < ApplicationJob
  limits_concurrency to: 2, key: ->(contact) { contact.account }, duration: 5.minutes

  def perform(contact)
    # ...
```
Where `contact` and `account` are `ActiveRecord` records. In this case, we'll ensure that at most two jobs of the kind `DeliverAnnouncementToContact` for the same account will run concurrently. If, for any reason, one of those jobs takes longer than 5 minutes or doesn't release its concurrency lock (signals the semaphore) within 5 minutes of acquiring it, a new job with the same key might gain the lock.

Let's see another example using `group`:

```ruby
class Box::MovePostingsByContactToDesignatedBoxJob < ApplicationJob
  limits_concurrency key: ->(contact) { contact }, duration: 15.minutes, group: "ContactActions"

  def perform(contact)
    # ...
```

```ruby
class Bundle::RebundlePostingsJob < ApplicationJob
  limits_concurrency key: ->(bundle) { bundle.contact }, duration: 15.minutes, group: "ContactActions"

  def perform(bundle)
    # ...
```

In this case, if we have a `Box::MovePostingsByContactToDesignatedBoxJob` job enqueued for a contact record with id `123` and another `Bundle::RebundlePostingsJob` job enqueued simultaneously for a bundle record that references contact `123`, only one of them will be allowed to proceed. The other one will stay blocked until the first one finishes (or 15 minutes pass, whatever happens first).

Note that the `duration` setting depends indirectly on the value for `concurrency_maintenance_interval` that you set for your dispatcher(s), as that'd be the frequency with which blocked jobs are checked and unblocked (at which point, only one job per concurrency key, at most, is unblocked). In general, you should set `duration` in a way that all your jobs would finish well under that duration and think of the concurrency maintenance task as a failsafe in case something goes wrong.

Jobs are unblocked in order of priority but queue order is not taken into account for unblocking jobs. That means that if you have a group of jobs that share a concurrency group but are in different queues, or jobs of the same class that you enqueue in different queues, the queue order you set for a worker is not taken into account when unblocking blocked ones. The reason is that a job that runs unblocks the next one, and the job itself doesn't know about a particular worker's queue order (you could even have different workers with different queue orders), it can only know about priority. Once blocked jobs are unblocked and available for polling, they'll be picked up by a worker following its queue order.

Finally, failed jobs that are automatically or manually retried work in the same way as new jobs that get enqueued: they get in the queue for getting an open semaphore, and whenever they get it, they'll be run. It doesn't matter if they had already gotten an open semaphore in the past.

## Failed jobs and retries

Solid Queue doesn't include any automatic retry mechanism, it [relies on Active Job for this](https://edgeguides.rubyonrails.org/active_job_basics.html#retrying-or-discarding-failed-jobs). Jobs that fail will be kept in the system, and a _failed execution_ (a record in the `solid_queue_failed_executions` table) will be created for these. The job will stay there until manually discarded or re-enqueued. You can do this in a console as:
```ruby
failed_execution = SolidQueue::FailedExecution.find(...) # Find the failed execution related to your job
failed_execution.error # inspect the error

failed_execution.retry # This will re-enqueue the job as if it was enqueued for the first time
failed_execution.discard # This will delete the job from the system
```

However, we recommend taking a look at [mission_control-jobs](https://github.com/rails/mission_control-jobs), a dashboard where, among other things, you can examine and retry/discard failed jobs.

### Error reporting on jobs

Some error tracking services that integrate with Rails, such as Sentry or Rollbar, hook into [Active Job](https://guides.rubyonrails.org/active_job_basics.html#exceptions) and automatically report not handled errors that happen during job execution. However, if your error tracking system doesn't, or if you need some custom reporting, you can hook into Active Job yourself. A possible way of doing this would be:

```ruby
# application_job.rb
class ApplicationJob < ActiveJob::Base
  rescue_from(Exception) do |exception|
    Rails.error.report(exception)
    raise exception
  end
end
```

Note that, you will have to duplicate the above logic on `ActionMailer::MailDeliveryJob` too. That is because `ActionMailer` doesn't inherit from `ApplicationJob` but instead uses `ActionMailer::MailDeliveryJob` which inherits from `ActiveJob::Base`.

```ruby
# application_mailer.rb

class ApplicationMailer < ActionMailer::Base
  ActionMailer::MailDeliveryJob.rescue_from(Exception) do |exception|
    Rails.error.report(exception)
    raise exception
  end
end
```

## Puma plugin

We provide a Puma plugin if you want to run the Solid Queue's supervisor together with Puma and have Puma monitor and manage it. You just need to add
```ruby
plugin :solid_queue
```
to your `puma.rb` configuration.

If you're using Puma in development but you don't want to use Solid Queue in development, make sure you avoid the plugin being used, for example using an environment variable like this:
```ruby
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]
```
that you set in production only. This is what Rails 8's default Puma config looks like. Otherwise, if you're using Puma in development but not Solid Queue, starting Puma would start also Solid Queue supervisor and it'll most likely fail because it won't be properly configured.


## Jobs and transactional integrity
:warning: Having your jobs in the same ACID-compliant database as your application data enables a powerful yet sharp tool: taking advantage of transactional integrity to ensure some action in your app is not committed unless your job is also committed and vice versa, and ensuring that your job won't be enqueued until the transaction within which you're enqueuing it is committed. This can be very powerful and useful, but it can also backfire if you base some of your logic on this behaviour, and in the future, you move to another active job backend, or if you simply move Solid Queue to its own database, and suddenly the behaviour changes under you. Because this can be quite tricky and many people shouldn't need to worry about it, by default Solid Queue is configured in a different database as the main app.

Starting from Rails 8, an option which doesn't rely on this transactional integrity and which Active Job provides is to defer the enqueueing of a job inside an Active Record transaction until that transaction successfully commits. This option can be set via the [`enqueue_after_transaction_commit`](https://edgeapi.rubyonrails.org/classes/ActiveJob/Enqueuing.html#method-c-enqueue_after_transaction_commit) class method on the job level and is by default disabled. Either it can be enabled for individual jobs or for all jobs through `ApplicationJob`:

```ruby
class ApplicationJob < ActiveJob::Base
  self.enqueue_after_transaction_commit = true
end
```

Using this option, you can also use Solid Queue in the same database as your app but not rely on transactional integrity.

If you don't set this option but still want to make sure you're not inadvertently on transactional integrity, you can make sure that:
- Your jobs relying on specific data are always enqueued on [`after_commit` callbacks](https://guides.rubyonrails.org/active_record_callbacks.html#after-commit-and-after-rollback) or otherwise from a place where you're certain that whatever data the job will use has been committed to the database before the job is enqueued.
- Or, you configure a different database for Solid Queue, even if it's the same as your app, ensuring that a different connection on the thread handling requests or running jobs for your app will be used to enqueue jobs. For example:

  ```ruby
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    connects_to database: { writing: :primary, reading: :replica }
  ```

  ```ruby
  config.solid_queue.connects_to = { database: { writing: :primary, reading: :replica } }
  ```


## Recurring tasks

Solid Queue supports defining recurring tasks that run at specific times in the future, on a regular basis like cron jobs. These are managed by the scheduler process and are defined in their own configuration file. By default, the file is located in `config/recurring.yml`, but you can set a different path using the environment variable `SOLID_QUEUE_RECURRING_SCHEDULE` or by using the `--recurring_schedule_file` option with `bin/jobs`, like this:

```
bin/jobs --recurring_schedule_file=config/schedule.yml
```

The configuration itself looks like this:

```yml
production:
  a_periodic_job:
    class: MyJob
    args: [ 42, { status: "custom_status" } ]
    schedule: every second
  a_cleanup_task:
    command: "DeletedStuff.clear_all"
    schedule: every day at 9am
```

Tasks are specified as a hash/dictionary, where the key will be the task's key internally. Each task needs to either have a `class`, which will be the job class to enqueue, or a `command`, which will be eval'ed in the context of a job (`SolidQueue::RecurringJob`) that will be enqueued according to its schedule, in the `solid_queue_recurring` queue.

Each task needs to have also a schedule, which is parsed using [Fugit](https://github.com/floraison/fugit), so it accepts anything [that Fugit accepts as a cron](https://github.com/floraison/fugit?tab=readme-ov-file#fugitcron). You can optionally supply the following for each task:
- `args`: the arguments to be passed to the job, as a single argument, a hash, or an array of arguments that can also include kwargs as the last element in the array.

The job in the example configuration above will be enqueued every second as:
```ruby
MyJob.perform_later(42, status: "custom_status")
```

- `queue`: a different queue to be used when enqueuing the job. If none, the queue set up for the job class.

- `priority`: a numeric priority value to be used when enqueuing the job.

Tasks are enqueued at their corresponding times by the scheduler, and each task schedules the next one. This is pretty much [inspired by what GoodJob does](https://github.com/bensheldon/good_job/blob/994ecff5323bf0337e10464841128fda100750e6/lib/good_job/cron_manager.rb).

For recurring tasks defined as a `command`, you can also change the job class that runs them as follows:
```ruby
Rails.application.config.after_initialize do # or to_prepare
  SolidQueue::RecurringTask.default_job_class = MyRecurringCommandJob
end
```

It's possible to run multiple schedulers with the same `recurring_tasks` configuration, for example, if you have multiple servers for redundancy, and you run the `scheduler` in more than one of them. To avoid enqueuing duplicate tasks at the same time, an entry in a new `solid_queue_recurring_executions` table is created in the same transaction as the job is enqueued. This table has a unique index on `task_key` and `run_at`, ensuring only one entry per task per time will be created. This only works if you have `preserve_finished_jobs` set to `true` (the default), and the guarantee applies as long as you keep the jobs around.

**Note**: a single recurring schedule is supported, so you can have multiple schedulers using the same schedule, but not multiple schedulers using different configurations.

Finally, it's possible to configure jobs that aren't handled by Solid Queue. That is, you can have a job like this in your app:
```ruby
class MyResqueJob < ApplicationJob
  self.queue_adapter = :resque

  def perform(arg)
    # ..
  end
end
```

You can still configure this in Solid Queue:
```yml
my_periodic_resque_job:
  class: MyResqueJob
  args: 22
  schedule: "*/5 * * * *"
```

and the job will be enqueued via `perform_later` so it'll run in Resque. However, in this case we won't track any `solid_queue_recurring_execution` record for it and there won't be any guarantees that the job is enqueued only once each time.

## Inspiration

Solid Queue has been inspired by [resque](https://github.com/resque/resque) and [GoodJob](https://github.com/bensheldon/good_job). We recommend checking out these projects as they're great examples from which we've learnt a lot.

## License
The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
