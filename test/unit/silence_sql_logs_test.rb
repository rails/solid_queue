require "test_helper"

class SilenceSqlLogsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "dispatcher polling SQL logs are silenced" do
    dispatcher = SolidQueue::Dispatcher.new(polling_interval: 0.1, batch_size: 10)
    log = StringIO.new
    with_active_record_logger(ActiveSupport::Logger.new(log)) do
      with_silence_sql_logs(true) do
        rewind_io(log)
        dispatcher.start
        sleep 0.5.second
      end
    end

    assert_no_match /SELECT .* FROM .solid_queue_scheduled_executions. WHERE/, log.string
  ensure
    dispatcher&.stop
  end

  test "dispatcher polling SQL logs are visible when not silenced" do
    dispatcher = SolidQueue::Dispatcher.new(polling_interval: 0.1, batch_size: 10)
    log = StringIO.new
    with_active_record_logger(ActiveSupport::Logger.new(log)) do
      with_silence_sql_logs(false) do
        rewind_io(log)
        dispatcher.start
        sleep 0.5.second
      end
    end

    assert_match /SELECT .* FROM .solid_queue_scheduled_executions. WHERE/, log.string
  ensure
    dispatcher&.stop
  end

  test "worker polling SQL logs are silenced" do
    worker = SolidQueue::Worker.new(queues: "background", threads: 3, polling_interval: 0.2)
    log = StringIO.new
    with_active_record_logger(ActiveSupport::Logger.new(log)) do
      with_silence_sql_logs(true) do
        worker.start
        sleep 0.2
      end
    end

    assert_no_match /SELECT .* FROM .solid_queue_ready_executions. WHERE .solid_queue_ready_executions...queue_name./, log.string
  ensure
    worker&.stop
  end

  test "worker polling SQL logs are visible when not silenced" do
    worker = SolidQueue::Worker.new(queues: "background", threads: 3, polling_interval: 0.2)
    log = StringIO.new
    with_active_record_logger(ActiveSupport::Logger.new(log)) do
      with_silence_sql_logs(false) do
        worker.start
        sleep 0.2
      end
    end

    assert_match /SELECT .* FROM .solid_queue_ready_executions. WHERE .solid_queue_ready_executions...queue_name./, log.string
  ensure
    worker&.stop
  end

  test "silencing SQL logs when there's no Active Record logger" do
    dispatcher = SolidQueue::Dispatcher.new(polling_interval: 0.1, batch_size: 10)
    with_active_record_logger(nil) do
      with_silence_sql_logs(true) do
        dispatcher.start
        sleep 0.5.second
      end
    end

    dispatcher.stop
    wait_for_registered_processes(0, timeout: 1.second)
    assert_no_registered_processes
  ensure
    dispatcher&.stop
  end

  test "heartbeat SQL logs are silenced" do
    old_heartbeat_interval, SolidQueue.process_heartbeat_interval = SolidQueue.process_heartbeat_interval, 0.1.second
    worker = SolidQueue::Worker.new(queues: "background", threads: 3, polling_interval: 10)
    log = StringIO.new
    with_active_record_logger(ActiveSupport::Logger.new(log)) do
      with_silence_sql_logs(true) do
        worker.start
        wait_for_registered_processes(1, timeout: 1.second)

        rewind_io(log)
        sleep 0.5
      end
    end

    assert_no_match /UPDATE .solid_queue_processes. SET .solid_queue_processes...last_heartbeat_at/, log.string
  ensure
    worker&.stop
    SolidQueue.process_heartbeat_interval = old_heartbeat_interval
  end

  test "heartbeat SQL logs are visible when not silenced" do
    old_heartbeat_interval, SolidQueue.process_heartbeat_interval = SolidQueue.process_heartbeat_interval, 0.1.second
    worker = SolidQueue::Worker.new(queues: "background", threads: 3, polling_interval: 10)
    log = StringIO.new
    with_active_record_logger(ActiveSupport::Logger.new(log)) do
      with_silence_sql_logs(false) do
        worker.start
        wait_for_registered_processes(1, timeout: 1.second)

        rewind_io(log)
        sleep 0.5
      end
    end

    assert_match /UPDATE .solid_queue_processes. SET .solid_queue_processes...last_heartbeat_at/, log.string
  ensure
    worker&.stop
    SolidQueue.process_heartbeat_interval = old_heartbeat_interval
  end

  test "enqueue SQL logs are silenced" do
    log = StringIO.new
    with_active_record_logger(ActiveSupport::Logger.new(log)) do
      with_silence_sql_logs(true) do
        rewind_io(log)
        AddToBufferJob.perform_later "test"
      end
    end

    assert_no_match /INSERT INTO .solid_queue_jobs./, log.string
  end

  test "enqueue SQL logs are visible when not silenced" do
    log = StringIO.new
    with_active_record_logger(ActiveSupport::Logger.new(log)) do
      with_silence_sql_logs(false) do
        rewind_io(log)
        AddToBufferJob.perform_later "test"
      end
    end

    assert_match /INSERT INTO .solid_queue_jobs./, log.string
  end

  private
    def with_silence_sql_logs(silence)
      old_silence, SolidQueue.silence_sql_logs = SolidQueue.silence_sql_logs, silence
      yield
    ensure
      SolidQueue.silence_sql_logs = old_silence
    end

    def with_active_record_logger(logger)
      old_logger, ActiveRecord::Base.logger = ActiveRecord::Base.logger, logger
      yield
    ensure
      ActiveRecord::Base.logger = old_logger
    end

    def rewind_io(log)
      log.truncate(0)
      log.rewind
    end
end
