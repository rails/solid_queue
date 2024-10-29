require "test_helper"

class SolidQueue::QueueTest < ActiveSupport::TestCase
  test "list all queues" do
    queue_names = [ "test", "test2", "the_queue", "backend" ]
    queue_names.each do |queue_name|
      (SecureRandom.random_number(5) + 1).times do |i|
        AddToBufferJob.set(queue: queue_name).perform_later(i)
      end
    end

    assert_equal queue_names.sort, SolidQueue::Queue.all.map(&:name).sort
  end
end
