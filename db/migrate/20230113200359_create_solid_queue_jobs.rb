class CreateSolidQueueJobs < ActiveRecord::Migration[7.0]
  def change
    create_table :solid_queue_jobs do |t|
      t.string :queue_name, null: false
      t.text :arguments

      t.integer :priority, default: 0, null: false
      t.string  :claimed_by

      t.datetime :claimed_at
      t.datetime :enqueued_at

      t.index [ :queue_name, :priority, :claimed_at ], name: :index_solid_queue_jobs_for_claims
      t.index :claimed_by
    end
  end
end
