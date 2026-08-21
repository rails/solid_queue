# frozen_string_literal: true

module SolidQueue
  # Kept for compatibility: concurrency maintenance runs on the shared
  # Dispatcher::Maintenance timer, together with batch maintenance.
  class Dispatcher::ConcurrencyMaintenance < Dispatcher::Maintenance
    def initialize(interval, batch_size)
      super(interval, batch_size, concurrency: true, batches: false)
    end
  end
end
