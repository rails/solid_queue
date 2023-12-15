# frozen_string_literal: true

module SolidQueue
  class Record < ActiveRecord::Base
    self.abstract_class = true

    connects_to **SolidQueue.connects_to if SolidQueue.connects_to

    def self.lock(...)
      if SolidQueue.use_skip_locked
        super(Arel.sql("FOR UPDATE SKIP LOCKED"))
      else
        super
      end
    end
  end
end

ActiveSupport.run_load_hooks :solid_queue_record, SolidQueue::Record
