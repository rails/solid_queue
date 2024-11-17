# frozen_string_literal: true

# Ideally, tests should be configured as close to production settings as
# possible and YJIT is likely to be enabled. While it's highly unlikely
# YJIT would cause issues, enabling it confirms this assertion.
#
# Configured via initializer to align with Rails 7.1 default in gemspec
if defined?(RubyVM::YJIT.enable)
  Rails.application.config.after_initialize do
    RubyVM::YJIT.enable
  end
end
