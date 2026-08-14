class AddUnlockKeysToProducts < ActiveRecord::Migration[8.1]
  def change
    # Unlock tokens are permanent and verified offline, forever, by clients that may never
    # phone home again. The only safe rotation is to ship TWO public keys in every client
    # and switch which one signs — the `kid` in the token header tells the client which to
    # use. "a" is the key already in products.eddsa_public_key; "b" is minted (and its
    # private half cold-stored, never written here) by rake unlock:generate_backup_key.
    add_column :products, :eddsa_key_id, :string, null: false, default: "a"
    add_column :products, :eddsa_backup_public_key, :string
    add_column :products, :eddsa_backup_key_id, :string

    # Loops template that carries the six digits.
    add_column :products, :unlock_transactional_id, :string
  end
end
