# Solid Queue

Solid Queue is a DB-based queuing backend for [Active Job](https://edgeguides.rubyonrails.org/active_job_basics.html). It can be used with SQL databases such as MySQL, PostgreSQL or SQLite.
It's been designed with simplicity and performance in mind. It relies on Active Job for retries, discarding, error handling, serialization, or delays, and it's compatible with Ruby on Rails muulti-threading.

## Usage
To set Solid Queue as your Active Job's queue backend, you should add this to your environment config:
```ruby
config.active_job.queue_adapter = :solid_queue
```

Alternatively, you can set only specific jobs to use Solid Queue as their backend if you're migrating from another adapter and want to move jobs progressively:

```ruby
class MyJob < ApplicationJob
  self.queue_adapter = :solid_queue
  # ...
end
```

## Installation
Add this line to your application's Gemfile:

```ruby
gem "solid_queue"
```

And then execute:
```bash
$ bundle
```

Or install it yourself as:
```bash
$ gem install solid_queue
```

Add the migration to your app and run it:
```
$ bin/rails solid_queue:install:migrations
$ bin/rails db:migrate
```

With this, you'll be ready to enqueue jobs using Solid Queue, but to run them, you need to configure Solid Queue's processes and start Solid Queue's supervisor. By default, Solid Queue will try to find your queues configuration under `config/solid_queue.yml`, but you can set a different path using the environment variable `SOLID_QUEUE_CONFIG`.

```yml
production:
  dispatcher:
    polling_interval: 1
    batch_size: 500
  workers:
    - queues: *

```
$ bundle exec rake solid_queue:start
```


## Configuration



## License
The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
