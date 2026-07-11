class AddAffiliateProgram < ActiveRecord::Migration[8.1]
  def change
    create_table :affiliates, id: :uuid do |t|
      t.string  :code, null: false
      t.string  :name, null: false
      t.string  :email, null: false
      t.string  :payout_email
      t.integer :commission_percent, null: false, default: 20
      t.string  :status, null: false, default: "pending"
      t.timestamps
      t.index :code,  unique: true
      t.index :email, unique: true
    end

    create_table :affiliate_tokens, id: :uuid do |t|
      t.references :affiliate, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.string   :token, null: false
      t.datetime :expires_at, null: false
      t.timestamps
      t.index :token, unique: true
    end

    create_table :payouts, id: :uuid do |t|
      t.references :affiliate, type: :uuid, null: false, foreign_key: true
      t.integer  :amount_cents, null: false
      t.string   :currency, null: false
      t.datetime :paid_at, null: false
      t.string   :note
      t.timestamps
    end

    add_reference :payments, :affiliate, type: :uuid, null: true, foreign_key: true, index: true
    add_column :payments, :commission_cents, :integer

    add_column :products, :affiliate_landing_url, :string
    add_column :products, :affiliate_transactional_id, :string
  end
end
