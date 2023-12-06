class AddIndexAndForeignKeysForClearing < ActiveRecord::Migration[7.1]
  def change
    add_index :solid_queue_jobs, :finished_at

    %w[ scheduled ready blocked claimed failed ].each do |execution_type|
      add_foreign_key "solid_queue_#{execution_type}_executions", :solid_queue_jobs, column: :job_id, on_delete: :cascade
    end
  end
end
