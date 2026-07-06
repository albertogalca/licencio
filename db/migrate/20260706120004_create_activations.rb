class CreateActivations < ActiveRecord::Migration[8.1]
  def change
    create_table :activations, id: :uuid do |t|
      t.references :license, null: false, foreign_key: true, type: :uuid
      t.string :hardware_id, null: false
      t.string :device_name
      t.datetime :activated_at, null: false
      t.datetime :deactivated_at

      t.timestamps
    end
  end
end
