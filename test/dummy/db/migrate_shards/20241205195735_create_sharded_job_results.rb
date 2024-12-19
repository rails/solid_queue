class CreateShardedJobResults < ActiveRecord::Migration[7.1]
  def change
    create_table :sharded_job_results do |t|
      t.string :value

      t.timestamps
    end
  end
end
