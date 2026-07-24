# frozen_string_literal: true

require "rails/generators/active_record"

class SolidQueue::UpdateGenerator < Rails::Generators::Base
  include ActiveRecord::Generators::Migration

  source_root File.expand_path("templates", __dir__)

  class_option :database, type: :string, aliases: %i[ --db ], default: "queue",
    desc: "The database that Solid Queue uses. Defaults to `queue`"

  def copy_new_migrations
    Dir.glob(File.join(self.class.source_root, "db", "*.rb")).each do |migration_file|
      name = File.basename(migration_file)
      migration_template File.join("db", name), File.join(db_migrate_path, name), skip: true
    end
  end
end
