# frozen_string_literal: true

module SolidQueue
  class Record < ActiveRecord::Base
    self.abstract_class = true

    connects_to(**SolidQueue.connects_to) if SolidQueue.connects_to

    class << self
      def connection
        if SolidQueue.connects_to.present?
          role = SolidQueue.connects_to.dig(:database)&.keys&.first || :writing
          connected_to(role: role) { super }        else
          super
        end
      end

      def non_blocking_lock
        if SolidQueue.use_skip_locked
          lock(Arel.sql("FOR UPDATE SKIP LOCKED"))
        else
          lock
        end
      end
    end
  end
end

ActiveSupport.run_load_hooks :solid_queue_record, SolidQueue::Record
