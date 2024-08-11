class AddNameToProcesses < ActiveRecord::Migration[7.1]
  def up
    add_column :solid_queue_processes, :name, :string

    SolidQueue::Process.find_each do |process|
      process.name ||= [ process.kind.downcase, SecureRandom.hex(10) ].join("-")
      process.save!
    end

    add_index :solid_queue_processes, [ :name, :supervisor_id ], unique: true
    change_column :solid_queue_processes, :name, :string, null: false
  end

  def down
    remove_index :solid_queue_processes, [ :name, :supervisor_id ]
    remove_column :solid_queue_processes, :name
  end
end
