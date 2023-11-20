class ImproveReadyExecutionIndexes < ActiveRecord::Migration[7.1]
  def change
    add_index :solid_queue_ready_executions, [ :queue_name, :priority, :job_id ], name: :index_solid_queue_poll_by_queue
    add_index :solid_queue_ready_executions, [ :priority, :job_id ], name: :index_solid_queue_poll_all

    remove_index :solid_queue_ready_executions, [ :queue_name, :priority ]
    remove_index :solid_queue_ready_executions, :priority
  end
end
