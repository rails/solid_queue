# frozen_string_literal: true

module SolidQueue
  class Record < ActiveRecord::Base
    self.abstract_class = true

    connects_to **SolidQueue.connects_to if SolidQueue.connects_to
  end
end

ActiveSupport.run_load_hooks :solid_queue_record, SolidQueue::Record
