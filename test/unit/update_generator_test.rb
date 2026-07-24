# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/solid_queue/update/update_generator"

class UpdateGeneratorTest < Rails::Generators::TestCase
  tests SolidQueue::UpdateGenerator
  destination Rails.root.join("tmp/update_generator_test")
  setup :prepare_destination

  test "copies new migrations to the queue database migrations path" do
    with_migration_template("add_batches_to_solid_queue") do
      run_generator

      assert_migration "db/queue_migrate/add_batches_to_solid_queue.rb" do |migration|
        assert_match(/class AddBatchesToSolidQueue/, migration)
      end
    end
  end

  test "copies new migrations to another database's migrations path" do
    with_migration_template("add_batches_to_solid_queue") do
      run_generator %w[ --database primary ]

      assert_migration "db/migrate/add_batches_to_solid_queue.rb"
    end
  end

  test "skips migrations that have already been copied" do
    with_migration_template("add_batches_to_solid_queue") do
      run_generator
      run_generator

      assert_equal 1, Dir.glob(File.join(destination_root, "db/queue_migrate/*_add_batches_to_solid_queue.rb")).count
    end
  end

  test "does nothing when there are no new migrations" do
    run_generator

    assert_empty Dir.glob(File.join(destination_root, "db/**/*.rb"))
  end

  private
    def with_migration_template(name)
      Dir.mktmpdir do |source_root|
        FileUtils.mkdir_p File.join(source_root, "db")
        File.write File.join(source_root, "db", "#{name}.rb"), <<~MIGRATION
          class #{name.camelize} < ActiveRecord::Migration[7.1]
            def change
            end
          end
        MIGRATION

        SolidQueue::UpdateGenerator.stubs(:source_root).returns(source_root)
        yield
      end
    end
end
