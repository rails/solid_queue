# frozen_string_literal: true

if Rails.gem_version < Gem::Version.new("8.1")
  module SolidQueue
    module Coders
      class JSON
        class << self
          delegate :dump, to: ::ActiveRecord::Coders::JSON
        end

        def self.load(json)
          ::JSON.parse(json) unless json.blank?
        end
      end
    end
  end
else
  module SolidQueue
    module Coders
      class JSON < ::ActiveRecord::Coders::JSON
        def load(json)
          ::JSON.parse(json, @options) unless json.blank?
        end
      end
    end
  end
end
