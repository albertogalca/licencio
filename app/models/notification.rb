class Notification < ApplicationRecord
  belongs_to :customer

  # Dedup guard for the one-shot lifecycle emails. `once` records a send keyed on
  # (customer, kind, reference) so a re-enqueue — or a job retry that already delivered —
  # doesn't re-send. create_or_find_by absorbs the concurrent-claim race on the unique index.
  #
  # ponytail: a job that fails AFTER Loops delivered but before sent_at is stamped can still
  # duplicate on retry — the only true fix is a Loops-side idempotency key; add one if Loops
  # ever exposes it.
  def self.once(customer:, kind:, reference_id:)
    record = create_or_find_by!(customer_id: customer.id, kind:, reference_id:)
    return if record.sent_at?
    yield
    record.update!(sent_at: Time.current)
  end
end
