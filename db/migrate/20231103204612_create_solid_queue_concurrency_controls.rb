class CreateSolidQueueConcurrencyControls < ActiveRecord::Migration[7.1]
  def change
    change_table :solid_queue_jobs do |t|
      t.integer :concurrency_limit
      t.string :concurrency_key
    end

    create_table :solid_queue_blocked_executions do |t|
      t.references :job, index: { unique: true }
      t.string :queue_name, null: false
      t.integer :priority, default: 0, null: false

      t.integer :concurrency_limit, null: false
      t.string :concurrency_key, null: false, index: true

      t.datetime :created_at, null: false
    end

    create_table :solid_queue_semaphores do |t|
      t.string :identifier, null: false, index: { unique: true }
      t.integer :value, null: false, default: 1

      t.timestamps
    end
  end
end
