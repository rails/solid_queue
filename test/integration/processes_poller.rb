# frozen_string_literal: true

require "test_helper"

class ProcessPollerTest < ActiveSupport::TestCase
  def test_active_record_logger_nil
    previous_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = nil
    pid = fork { SolidQueue::Supervisor.start }
    sleep 1
  ensure
    ActiveRecord::Base.logger = previous_logger
    terminate_process(pid) if pid && process_exists?(pid)
  end

  def test_active_record_logger_logger_dev_null
    previous_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = Logger.new("/dev/null")
    pid = fork { SolidQueue::Supervisor.start }
    sleep 1
  ensure
    ActiveRecord::Base.logger = previous_logger
    terminate_process(pid) if pid && process_exists?(pid)
  end

  def test_active_record_logger_active_support_logger_dev_null
    previous_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = ActiveSupport::Logger.new("/dev/null")
    pid = fork { SolidQueue::Supervisor.start }
    sleep 1
  ensure
    ActiveRecord::Base.logger = previous_logger
    terminate_process(pid) if pid && process_exists?(pid)
  end
end
