# Upgrading to version 0.4.x
This version introduced an _async_ mode to run the supervisor and have all workers and dispatchers run as part of the same process as the supervisor, instead of separate, forked, processes. Together with this, we introduced some changes in how the supervisor is started. Prior this change, you could choose whether you wanted to run workers, dispatchers or both, by starting Solid Queue as `solid_queue:work` or `solid_queue:dispatch`. From version 0.4.0, the only option available is:

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
