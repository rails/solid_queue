module SolidQueue
  class Pause < Record
    def self.all_queue_names
      all.pluck(:queue_name)
    end
  end
end
