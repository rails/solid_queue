# frozen_string_literal: true

class SolidQueue::RecurringJob < ActiveJob::Base
  queue_as :solid_queue_recurring

  def perform(command)
    eval(command)
  end
end
