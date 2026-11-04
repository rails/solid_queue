# frozen_string_literal: true

require "test_helper"

class EnqueueBufferTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    SolidQueue.buffer_enqueues_on_database_error = true
    # The flusher thread is exercised on its own; elsewhere flush by hand.
    SolidQueue::EnqueueBuffer.stubs(:start_flushing)
  end

  teardown do
    SolidQueue.buffer_enqueues_on_database_error = false
    SolidQueue.enqueue_buffer_size = 1_000
    SolidQueue::EnqueueBuffer.reset
  end

  test "an enqueue that can't reach the database is held and reported as enqueued" do
    database_unreachable_for(:create!)

    job = AddToBufferJob.set(queue: :critical, priority: 7).perform_later(42)

    assert job.successfully_enqueued?
    assert_nil job.provider_job_id
    assert_equal 1, SolidQueue::EnqueueBuffer.size
    assert_equal 0, SolidQueue::Job.count
  end

  test "held jobs are enqueued as they were once the database is back" do
    database_unreachable_for(:create!)
    job = AddToBufferJob.set(queue: :critical, priority: 7, wait: 5.minutes).perform_later(42)
    SolidQueue::Job.unstub(:create!)

    assert SolidQueue::EnqueueBuffer.flush

    enqueued = SolidQueue::Job.find_by!(active_job_id: job.job_id)
    assert_equal [ "critical", 7 ], [ enqueued.queue_name, enqueued.priority ]
    assert_in_delta job.scheduled_at, enqueued.scheduled_at, 1.second
    assert enqueued.scheduled?
    assert_equal enqueued.id, job.provider_job_id
    assert_equal 0, SolidQueue::EnqueueBuffer.size
  end

  test "a bulk enqueue that can't reach the database is held as a whole" do
    database_unreachable_for(:insert_all, ActiveRecord::ConnectionFailed)
    jobs = [ AddToBufferJob.new(1), AddToBufferJob.new(2) ]

    assert_equal 2, SolidQueue::Job.enqueue_all(jobs)

    assert jobs.all?(&:successfully_enqueued?)
    assert_equal 2, SolidQueue::EnqueueBuffer.size
  end

  test "held jobs stay held while the database is still unreachable" do
    database_unreachable_for(:create!)
    AddToBufferJob.perform_later(42)
    database_unreachable_for(:insert_all)

    assert_not SolidQueue::EnqueueBuffer.flush
    assert_equal 1, SolidQueue::EnqueueBuffer.size
  end

  test "enqueue errors raise as before when buffering is off" do
    SolidQueue.buffer_enqueues_on_database_error = false
    database_unreachable_for(:create!)

    assert_raises(SolidQueue::Job::EnqueueError) { AddToBufferJob.perform_later(42) }
    assert_equal 0, SolidQueue::EnqueueBuffer.size
  end

  test "errors other than an unreachable database still raise" do
    SolidQueue::Job.stubs(:create!).raises(ActiveRecord::StatementInvalid)

    assert_raises(SolidQueue::Job::EnqueueError) { AddToBufferJob.perform_later(42) }
    assert_equal 0, SolidQueue::EnqueueBuffer.size
  end

  test "enqueues raise once the buffer is full" do
    SolidQueue.enqueue_buffer_size = 1
    database_unreachable_for(:create!)
    AddToBufferJob.perform_later(1)

    assert_raises(SolidQueue::Job::EnqueueError) { AddToBufferJob.perform_later(2) }
    assert_equal 1, SolidQueue::EnqueueBuffer.size
  end

  test "the flusher enqueues held jobs in the background and then stops" do
    SolidQueue::EnqueueBuffer.unstub(:start_flushing)
    SolidQueue::EnqueueBuffer.stubs(:sleep)
    database_unreachable_for(:create!) # the flusher enqueues through insert_all, which works

    job = AddToBufferJob.perform_later(42)

    wait_for(timeout: 5.seconds) { SolidQueue::EnqueueBuffer.instance_variable_get(:@flusher).nil? }
    assert SolidQueue::Job.exists?(active_job_id: job.job_id)
    assert_equal 0, SolidQueue::EnqueueBuffer.size
  end

  test "held jobs still unenqueued at exit are reported as lost" do
    database_unreachable_for(:create!)
    AddToBufferJob.perform_later(42)
    database_unreachable_for(:insert_all)
    lost = []
    subscriber = ActiveSupport::Notifications.subscribe("lose_held_jobs.solid_queue") { |event| lost << event.payload[:size] }

    SolidQueue::EnqueueBuffer.send(:flush_on_exit)

    assert_equal [ 1 ], lost
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "a forked child doesn't inherit held jobs" do
    database_unreachable_for(:create!)
    AddToBufferJob.perform_later(42)

    reader, writer = IO.pipe
    pid = fork do
      reader.close
      writer.puts SolidQueue::EnqueueBuffer.size
      writer.close
    end
    writer.close
    Process.wait(pid)

    assert_equal "0", reader.read.strip
    assert_equal 1, SolidQueue::EnqueueBuffer.size
  end

  private
    def database_unreachable_for(method, error = ActiveRecord::ConnectionNotEstablished)
      SolidQueue::Job.stubs(method).raises(error)
    end
end
