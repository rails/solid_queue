class CreateSolidQueueFailedJobs < ActiveRecord::Migration[7.0]
  def change
    create_table :solid_queue_failed_jobs do |t|
      t.string :queue_name, null: false
      t.text :arguments

      t.text :error

      t.integer :priority, default: 0, null: false

      t.datetime :enqueued_at

      t.index [ :queue_name, :priority ]
    end
  end
end
