class RemoveUnusedIndexes < ActiveRecord::Migration[7.1]
  def change
    remove_index :solid_queue_blocked_executions, [ :concurrency_key, :expires_at ], name: "index_solid_queue_blocked_executions_for_maintenance_2"
    remove_index :solid_queue_blocked_executions, [ :concurrency_key, :priority, :job_id ], name: "index_solid_queue_blocked_executions_for_release"
  end
end
