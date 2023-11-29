class ExtendClaimedExecutionsIndexOnProcessId < ActiveRecord::Migration[7.1]
  def change
    add_index :solid_queue_claimed_executions, [ :process_id, :job_id ]
    remove_index :solid_queue_claimed_executions, :process_id
  end
end
