class CreateSolidQueueTables < ActiveRecord::Migration[7.0]
  def change
    create_table :solid_queue_jobs do |t|
      t.string :queue_name, null: false
      t.text :arguments

      t.integer :priority, default: 0, null: false

      t.datetime :scheduled_at
      t.datetime :finished_at

      t.timestamps

      t.index [ :finished_at, :scheduled_at ]
    end

    create_table :solid_queue_ready_executions do |t|
      t.references :job, index: { unique: true }
      t.string :queue_name, null: false
      t.integer :priority, default: 0, null: false

      t.datetime :created_at, null: false

      t.index [ :queue_name, :priority ]
    end

    create_table :solid_queue_claimed_executions do |t|
      t.references :job, index: { unique: true }
      t.string :claimed_by

      t.datetime :created_at, null: false
    end

    create_table :solid_queue_failed_executions do |t|
      t.references :job, index: { unique: true }
      t.text :error

      t.datetime :created_at, null: false
    end
  end
end
