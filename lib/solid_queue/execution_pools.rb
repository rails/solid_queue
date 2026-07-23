# frozen_string_literal: true

module SolidQueue
  module ExecutionPools
    def self.build(type:, size:, on_idle: nil)
      const_get("#{type.to_s.camelize}Pool").new(size, on_idle: on_idle)
    end
  end
end
