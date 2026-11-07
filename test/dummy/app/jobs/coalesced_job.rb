class CoalescedJob < ApplicationJob
  coalesce key: ->(name) { name }

  def perform(name)
    JobBuffer.add(name)
  end
end
