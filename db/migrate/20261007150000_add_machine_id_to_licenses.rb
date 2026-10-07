# One trial per machine. machine_id is a salted SHA-256 of the OS machine id, sent by the
# desktop app only with the keyless trial request; hardware_id stays the seat identity.
# Unique per product so two racing first requests from one machine cannot mint two trials.
class AddMachineIdToLicenses < ActiveRecord::Migration[8.1]
  def change
    add_column :licenses, :machine_id, :string
    add_index :licenses, [ :product_id, :machine_id ], unique: true, where: "machine_id IS NOT NULL",
      name: "index_licenses_on_product_and_machine_id"
  end
end
