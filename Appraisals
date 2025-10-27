# frozen_string_literal: true

appraise "rails-7-1" do
  # rdoc 6.14 is not compatible with Ruby 3.1
  gem 'rdoc', '6.13'
  gem "railties", "~> 7.1.0"
end

appraise "rails-7-2" do
  gem 'rdoc', '6.13'
  gem "railties", "~> 7.2.0"
end

appraise "rails-8-0" do
  gem "railties", "~> 8.0.0"
end

appraise "rails-8-1" do
  gem "railties", "~> 8.1.0"
end

appraise "rails-main" do
  gem "railties", github: "rails/rails", branch: "main"
end
