class CreateRecurringTasks < ActiveRecord::Migration[7.1]
  def change
    create_table :solid_queue_recurring_tasks do |t|
      t.string :key, null: false, index: { unique: true }
      t.string :schedule, null: false
      t.string :class_name, null: false
      t.text :arguments

      t.timestamps
    end
  end
end
