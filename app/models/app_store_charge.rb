# One App Store one-time purchase, as Apple's server notification reported it. Free and paid
# products alike: a $0 purchase that starts a trial is a charge of 0. A charge mints nothing;
# licenses come from claims. This is the record of what was bought, when and by whom.
class AppStoreCharge < ApplicationRecord
  belongs_to :product

  enum :environment, AppStoreTransaction::ENVIRONMENTS.values.index_by(&:itself)

  scope :free, -> { where(amount_cents: 0) }
  scope :paid, -> { where(amount_cents: 1..) }
  scope :unrevoked, -> { where(revoked_at: nil) }

  # Apple redelivers until it gets a 200, and a transaction never changes once made, so the
  # first verified delivery is kept and every later one is a no-op.
  def self.record!(store_transaction)
    insert({ store_product_id: store_transaction.product_id,
      transaction_id: store_transaction.transaction_id,
      original_transaction_id: store_transaction.original_transaction_id,
      app_transaction_id: store_transaction.app_transaction_id,
      bundle_id: store_transaction.bundle_id,
      environment: store_transaction.environment,
      purchased_at: store_transaction.purchase_date,
      amount_cents: store_transaction.amount_cents,
      currency: store_transaction.currency,
      storefront: store_transaction.storefront,
      revoked_at: store_transaction.revocation_date }, unique_by: :transaction_id)
  end

  def self.revoke!(store_transaction)
    where(transaction_id: store_transaction.transaction_id)
      .update_all(revoked_at: store_transaction.revocation_date || Time.current)
  end
end
