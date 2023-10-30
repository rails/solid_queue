class MakeJobIdNotNull < ActiveRecord::Migration[7.1]
  def change
    change_column :solid_queue_claimed_executions, :job_id, :bigint, null: false
    change_column :solid_queue_failed_executions, :job_id, :bigint, null: false
    change_column :solid_queue_ready_executions, :job_id, :bigint, null: false
    change_column :solid_queue_scheduled_executions, :job_id, :bigint, null: false
  end
end
