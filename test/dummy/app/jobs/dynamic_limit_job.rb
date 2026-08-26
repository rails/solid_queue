# frozen_string_literal: true

class DynamicLimitJob < ApplicationJob
  class << self
    attr_accessor :limits, :evaluations
  end

  self.limits = Hash.new(2)
  self.evaluations = Hash.new(0)

  limits_concurrency \
    key: ->(tenant_id, *) { "tenant/#{tenant_id}" },
    to: ->(tenant_id, *) {
      DynamicLimitJob.evaluations[tenant_id] += 1
      DynamicLimitJob.limits[tenant_id]
    },
    group: ->(*) { nil }

  def perform(tenant_id)
  end
end
