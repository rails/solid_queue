class AddCoalesceKeysToSolidQueue < ActiveRecord::Migration[7.1]
  def change
    # Fresh installs create this with the base schema, so skip it if it
    # already exists
    create_table :solid_queue_coalesce_keys, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :job_id
      t.datetime :created_at, null: false

      t.index :key, unique: true
      t.index :job_id, unique: true
      t.foreign_key :solid_queue_jobs, column: :job_id, on_delete: :cascade
    end
  end
end
