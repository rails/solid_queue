# Upgrading to version 1.x
The value returned for `enqueue_after_transaction_commit?` has changed to `true`, and it's no longer configurable. If you want to change this, you need to use Active Job's configuration options.

# Upgrading to version 0.9.x
This version has two breaking changes regarding configuration:
- The default configuration file has changed from `config/solid_queue.yml` to `config/queue.yml`.
- Recurring tasks are now defined in `config/recurring.yml` (by default). Before, they would be defined as part of the _dispatcher_ configuration. Now they've been upgraded to their own configuration file, and a dedicated process (the _scheduler_) to manage them. Check the _Recurring tasks_ section in the `README` to learn how to configure them in detail. They still follow the same format as before when they lived under `dispatchers > recurring_tasks`.

# Upgrading to version 0.8.x
*IMPORTANT*: This version collapsed all migrations into a single `db/queue_schema.rb`, that will use a separate `queue` database on install. If you're upgrading from a version < 0.6.0, you need to upgrade to 0.6.0 first, ensure all migrations are up-to-date, and then upgrade further. You don't have to switch to a separate `queue` database or use the new `db/queue_schema.rb` file, these are for people starting on a version >= 0.8.x. You can continue using your existing database (be it separate or the same as your app) as long as you run all migrations defined up to version 0.6.0.

# Upgrading to version 0.7.x

This version removed the new async mode introduced in version 0.4.0 and introduced a new binstub that can be used to start Solid Queue's supervisor.

To install the binstub `bin/jobs`, you can just run:
```
bin/rails generate solid_queue:install
```


# Upgrading to version 0.6.x

## New migration in 3 steps
This version adds two new migrations to modify the `solid_queue_processes` table. The goal of that migration is to add a new column that needs to be `NOT NULL`. This needs to be done with two migrations and the following steps to ensure it happens without downtime and with new processes being able to register just fine:
1. Run the first migration that adds the new column, nullable
2. Deploy the updated Solid Queue code that uses this column
2. Run the second migration. This migration does two things:
  - Backfill existing rows that would have the column as NULL
  - Make the column not nullable and add a new index

Besides, it adds another migration with no effects to the `solid_queue_recurring_tasks` table. This one can be run just fine whenever, as the column affected is not used.

To install the migrations:
```bash
$ bin/rails solid_queue:install:migrations
```

Or, if you're using a different database for Solid Queue:

```bash
$ bin/rails solid_queue:install:migrations DATABASE=<the_name_of_your_solid_queue_db>
```

And then follow the steps above, running first one, then deploying the code, then running the second one.

## New behaviour when workers are killed
From this version onwards, when a worker is killed and the supervisor can detect that, it'll fail in-progress jobs claimed by that worker. For this to work correctly, you need to run the above migration and ensure you restart any supervisors you'd have. 


# Upgrading to version 0.5.x
This version includes a new migration to improve recurring tasks. To install it, just run:

```bash
$ bin/rails solid_queue:install:migrations
```

Or, if you're using a different database for Solid Queue:

```bash
$ bin/rails solid_queue:install:migrations DATABASE=<the_name_of_your_solid_queue_db>
```

And then run the migrations.


# Upgrading to version 0.4.x
This version introduced an _async_ mode (this mode has been removed in version 0.7.0) to run the supervisor and have all workers and dispatchers run as part of the same process as the supervisor, instead of separate, forked, processes. Together with this, we introduced some changes in how the supervisor is started. Prior this change, you could choose whether you wanted to run workers, dispatchers or both, by starting Solid Queue as `solid_queue:work` or `solid_queue:dispatch`. From version 0.4.0, the only option available is:

```
$ bundle exec rake solid_queue:start
```
Whether the supervisor starts workers, dispatchers or both will depend on your configuration. For example, if you don't configure any dispatchers, only workers will be started. That is, with this configuration:

```yml
production:
  workers:
    - queues: [ real_time, background ]
      threads: 5
      polling_interval: 0.1
      processes: 3
```
the supervisor will run 3 workers, each one with 5 threads, and no supervisors. With this configuration:
```yml
production:
  dispatchers:
    - polling_interval: 1
      batch_size: 500
      concurrency_maintenance_interval: 300
```
the supervisor will run 1 dispatcher and no workers.


# Upgrading to version 0.3.x
This version introduced support for [recurring (cron-style) jobs](https://github.com/rails/solid_queue/blob/main/README.md#recurring-tasks), and it needs a new DB migration for it. To install it, just run:

```bash
$ bin/rails solid_queue:install:migrations
```

Or, if you're using a different database for Solid Queue:

```bash
$ bin/rails solid_queue:install:migrations DATABASE=<the_name_of_your_solid_queue_db>
```

And then run the migrations.
