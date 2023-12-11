class AddNewAttributesToProcesses < ActiveRecord::Migration[7.1]
  def change
    change_table :solid_queue_processes do |t|
      t.string :kind, null: false
      t.string :hostname
      t.integer :pid, null: false
    end
  end
end
