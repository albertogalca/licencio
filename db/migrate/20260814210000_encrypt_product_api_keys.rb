class EncryptProductApiKeys < ActiveRecord::Migration[8.1]
  # Bare model: the real Product has validations and callbacks that have no business running
  # during a data migration. It exists only to borrow the encrypted attribute type below.
  class MigrationProduct < ActiveRecord::Base
    self.table_name = "products"
    encrypts :api_key, deterministic: true
  end

  # Rewrites the existing plaintext keys as ciphertext, in raw SQL on purpose: assigning the
  # value back through the model leaves the record not-dirty, so no UPDATE is issued, and
  # update_all would run the already-serialized string through the type a second time.
  def up
    each_api_key { |id, value, type| store(id, type.serialize(value)) unless encrypted?(type, value) }
  end

  def down
    each_api_key { |id, value, type| store(id, type.deserialize(value)) if encrypted?(type, value) }
  end

  private
    def each_api_key
      type = MigrationProduct.type_for_attribute("api_key")
      select_all("SELECT id, api_key FROM products").each { |row| yield row["id"], row["api_key"], type }
    end

    def store(id, value)
      execute(ActiveRecord::Base.sanitize_sql([ "UPDATE products SET api_key = ? WHERE id = ?", value, id ]))
    end

    # Ciphertext decrypts to something other than itself; plaintext just fails to decrypt. Makes
    # the migration idempotent, and safe on a table that is half-migrated.
    def encrypted?(type, value)
      type.deserialize(value) != value
    rescue ActiveRecord::Encryption::Errors::Decryption
      false
    end
end
