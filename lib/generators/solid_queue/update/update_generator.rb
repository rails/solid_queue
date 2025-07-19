# frozen_string_literal: true

require "rails/generators/active_record"

class SolidQueue::UpdateGenerator < Rails::Generators::Base
  include ActiveRecord::Generators::Migration

  source_root File.expand_path("templates", __dir__)

  class_option :database, type: :string, aliases: %i[ --db ], default: "queue",
    desc: "The database that Solid Queue uses. Defaults to `queue`"

  def copy_new_migrations
    template_dir = Dir.new(File.join(self.class.source_root, "db"))

    template_dir.each_child do |migration_file|
      migration_template File.join("db", migration_file), File.join(db_migrate_path, migration_file), skip: true
    end
  end
end
