class MakeNameNotNull < ActiveRecord::Migration[7.1]
  def up
    SolidQueue::Process.where(name: nil).find_each do |process|
      process.name ||= [ process.kind.downcase, SecureRandom.hex(10) ].join("-")
      process.save!
    end

    change_column :solid_queue_processes, :name, :string, null: false
    add_index :solid_queue_processes, [ :name, :supervisor_id ], unique: true
  end

  def down
    remove_index :solid_queue_processes, [ :name, :supervisor_id ]
    change_column :solid_queue_processes, :name, :string, null: true
  end
end
