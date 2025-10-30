require "test_helper"

class SolidQueue::ReadyExecutionTest < ActiveSupport::TestCase
  setup do
    5.times do |i|
      AddToBufferJob.set(queue: "backend", priority: 5 - i).perform_later(i)
    end

    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "worker-123", metadata: { queue: "background" })
    @jobs = SolidQueue::Job.where(queue_name: "backend").order(:priority)
  end

  test "claim all jobs for existing queue" do
    assert_claimed_jobs(@jobs.count) do
      SolidQueue::ReadyExecution.claim("backend", @jobs.count + 1, @process)
    end

    @jobs.each(&:reload)
    assert @jobs.none?(&:ready?)
    assert @jobs.all?(&:claimed?)
  end

  test "claim jobs for queue without jobs at the moment" do
    assert_no_difference [ -> { SolidQueue::ReadyExecution.count }, -> { SolidQueue::ClaimedExecution.count } ] do
      SolidQueue::ReadyExecution.claim("some_non_existing_queue", 10, @process)
    end
  end

  test "claim some jobs for existing queue" do
    assert_claimed_jobs(2) do
      SolidQueue::ReadyExecution.claim("backend", 2, @process)
    end

    @jobs.first(2).each do |job|
      assert_not job.reload.ready?
      assert job.claimed?
    end

    @jobs.order(:priority)[2..-1].each do |job|
      assert job.reload.ready?
      assert_not job.claimed?
    end
  end

  test "claim jobs using a list of queues" do
    AddToBufferJob.perform_later("hey")

    assert_claimed_jobs(6) do
      SolidQueue::ReadyExecution.claim(%w[ backend background ], SolidQueue::Job.count + 1, @process)
    end
  end

  test "claim jobs using a wildcard" do
    AddToBufferJob.perform_later("hey")

    assert_claimed_jobs(6) do
      SolidQueue::ReadyExecution.claim("*", SolidQueue::Job.count + 1, @process)
    end
  end

  test "claim jobs using queue prefixes" do
    AddToBufferJob.perform_later("hey")

    assert_claimed_jobs(1) do
      SolidQueue::ReadyExecution.claim("backgr*", SolidQueue::Job.count + 1, @process)
    end

    assert @jobs.none?(&:claimed?)
  end

  test "claim jobs using a wildcard and having paused queues" do
    AddToBufferJob.perform_later("hey")

    SolidQueue::Queue.find_by_name("backend").pause

    assert_claimed_jobs(1) do
      SolidQueue::ReadyExecution.claim("*", SolidQueue::Job.count + 1, @process)
    end

    @jobs.each(&:reload)
    assert @jobs.none?(&:claimed?)
  end

  test "claim jobs using both exact names and a prefix" do
    AddToBufferJob.perform_later("hey")

    assert_claimed_jobs(6) do
      SolidQueue::ReadyExecution.claim(%w[ backe* background ], SolidQueue::Job.count + 1, @process)
    end
  end

  test "claim jobs for queue without jobs at the moment using prefixes" do
    AddToBufferJob.perform_later("hey")

    assert_claimed_jobs(0) do
      SolidQueue::ReadyExecution.claim(%w[ none* ], SolidQueue::Job.count + 1, @process)
    end
  end

  test "priority order is used when claiming jobs using a wildcard" do
    AddToBufferJob.set(priority: 1).perform_later("hey")
    job = SolidQueue::Job.last

    assert_claimed_jobs(3) do
      SolidQueue::ReadyExecution.claim("*", 3, @process)
    end

    assert job.reload.claimed?
    @jobs.first(2).each do |job|
      assert_not job.reload.ready?
      assert job.claimed?
    end
  end

  test "queue order and then priority is respected when using a list of queues" do
    AddToBufferJob.perform_later("hey")
    job = SolidQueue::Job.last
    assert_equal "background", job.queue_name

    assert_claimed_jobs(3) do
      SolidQueue::ReadyExecution.claim(%w[ background backend ], 3, @process)
    end

    assert job.reload.claimed?
    @jobs.first(2).each do |job|
      assert_not job.reload.ready?
      assert job.claimed?
    end
  end

  test "queue order is respected when using prefixes" do
    %w[ queue_b1 queue_b2 queue_a2 queue_a1 queue_b1 queue_a2 queue_b2 queue_a1 ].each do |queue_name|
      AddToBufferJob.set(queue: queue_name).perform_later(1)
    end

    # Claim 8 jobs
    claimed_jobs = []
    4.times do
      assert_claimed_jobs(2) do
        SolidQueue::ReadyExecution.claim(%w[ queue_b* queue_a* ], 2, @process)
      end

      claimed_jobs += SolidQueue::ClaimedExecution.order(:id).last(2).map(&:job)
    end

    # Check claim order
    assert_equal %w[ queue_b1 queue_b1 queue_b2 queue_b2 queue_a1 queue_a1 queue_a2 queue_a2 ],
      claimed_jobs.map(&:queue_name)
  end


  test "queue order is respected when mixing exact names with prefixes" do
    %w[ queue_b1 queue_b2 queue_a2 queue_c2 queue_a1 queue_c1 queue_b1 queue_a2 queue_b2 queue_a1 ].each do |queue_name|
      AddToBufferJob.set(queue: queue_name).perform_later(1)
    end

    # Claim 10 jobs
    claimed_jobs = []
    5.times do
      assert_claimed_jobs(2) do
        SolidQueue::ReadyExecution.claim(%w[ queue_a2 queue_c1 queue_b* queue_c2 queue_a* ], 2, @process)
      end

      claimed_jobs += SolidQueue::ClaimedExecution.order(:id).last(2).map(&:job)
    end

    # Check claim order
    assert_equal %w[ queue_a2 queue_a2 queue_c1 queue_b1 queue_b1 queue_b2 queue_b2 queue_c2 queue_a1 queue_a1 ],
      claimed_jobs.map(&:queue_name)
  end

  test "discard all" do
    3.times { |i| AddToBufferJob.perform_later(i) }

    assert_difference [ -> { SolidQueue::ReadyExecution.count }, -> { SolidQueue::Job.count } ], -8 do
      SolidQueue::ReadyExecution.discard_all_in_batches
    end
  end

  test "discard all by queue" do
    3.times { |i| AddToBufferJob.perform_later(i) }

    assert_difference [ -> { SolidQueue::ReadyExecution.count }, -> { SolidQueue::Job.count } ], -5 do
      SolidQueue::ReadyExecution.queued_as(:backend).discard_all_in_batches
    end

    assert_no_difference [ -> { SolidQueue::ReadyExecution.count }, -> { SolidQueue::Job.count } ] do
      SolidQueue::ReadyExecution.queued_as(:backend).discard_all_in_batches
    end
  end

  private
    def assert_claimed_jobs(count, &block)
      assert_difference -> { SolidQueue::ClaimedExecution.count } => +count, -> { SolidQueue::ReadyExecution.count } => -count do
        block.call
      end
    end
end
