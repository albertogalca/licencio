class DropMagicLinkTemplate < ActiveRecord::Migration[8.0]
  # One transactional template now covers both purchase (license key) and portal access (magic link).
  def change
    remove_column :products, :loops_magic_link_transactional_id, :string
  end
end
