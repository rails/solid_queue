Rails.application.config.x.solid_queue_record_hook_ran = false

ActiveSupport.on_load(:solid_queue_record) do
  raise "Expected to run on SolidQueue::Record, got #{self.inspect}" unless self == SolidQueue::Record
  Rails.application.config.x.solid_queue_record_hook_ran = true
end
