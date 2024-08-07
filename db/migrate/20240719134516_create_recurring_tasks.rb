class CreateRecurringTasks < ActiveRecord::Migration[7.1]
  def change
    create_table :solid_queue_recurring_tasks do |t|
      t.string :key, null: false, index: { unique: true }
      t.string :schedule, null: false
      t.string :command, limit: 2048
      t.string :class_name
      t.text :arguments

      t.string :queue_name
      t.integer :priority, default: 0

      t.boolean :static, default: true, index: true

      t.text :description

      t.timestamps
    end
  end
end
