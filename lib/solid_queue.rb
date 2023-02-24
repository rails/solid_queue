require "solid_queue/version"
require "solid_queue/engine"

require "active_job/queue_adapters/solid_queue_adapter"

require "solid_queue/configuration"
require "solid_queue/runnable"
require "solid_queue/processes"
require "solid_queue/dispatcher"
require "solid_queue/scheduler"
require "solid_queue/supervisor"

module SolidQueue
  mattr_accessor :logger, default: ActiveSupport::Logger.new($stdout)
end
