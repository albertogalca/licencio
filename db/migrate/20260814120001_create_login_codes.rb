class CreateLoginCodes < ActiveRecord::Migration[8.1]
  def change
    # The six digits mailed to a buyer's inbox, in exchange for an entitlement token.
    # Only the hash is stored, and the pepper (secret_key_base) lives outside the
    # database — a stolen dump alone doesn't mint unlocks.
    create_table :login_codes, id: :uuid do |t|
      t.references :product, null: false, foreign_key: true, type: :uuid
      t.string :email, null: false        # normalized form (Purchase.normalize_email)
      t.string :code_hash, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.integer :attempts, null: false, default: 0
      t.timestamps
    end

    # Support timeline: "did they ever get a code, and when".
    add_index :login_codes, [ :product_id, :email, :created_at ]
    # The hot path: the newest live code for an address. Partial, because a consumed code
    # is history and every lookup filters it out.
    add_index :login_codes, [ :product_id, :email ], where: "consumed_at IS NULL",
      name: "index_login_codes_on_product_and_email_unconsumed"
  end
end
