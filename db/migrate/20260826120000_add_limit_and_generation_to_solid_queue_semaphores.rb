# frozen_string_literal: true

class AddLimitAndGenerationToSolidQueueSemaphores < ActiveRecord::Migration[7.1]
  def change
    add_column :solid_queue_semaphores, :limit, :integer
    add_column :solid_queue_semaphores, :generation, :integer, default: 0, null: false
  end
end
