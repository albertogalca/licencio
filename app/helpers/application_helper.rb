module ApplicationHelper
  # Real photo when the customer has a Gravatar; a unique identicon otherwise.
  def gravatar_url(email, size: 40)
    hash = Digest::MD5.hexdigest(email.to_s.strip.downcase)
    "https://www.gravatar.com/avatar/#{hash}?d=identicon&s=#{size}"
  end

  STATUS_BADGE_VARIANTS = {
    "active" => "badge-emerald",
    "expired" => "badge-amber",
    "refunded" => "badge-red",
    "inactive" => "badge-gray",
    "approved" => "badge-emerald",
    "pending" => "badge-amber",
    "rejected" => "badge-red"
  }.freeze

  # ponytail: string format, no symbols. Swap for number_to_currency if a $/€ glyph is ever needed.
  def money_cents(cents, currency = "EUR")
    "#{"%.2f" % (cents.to_i / 100.0)} #{currency.to_s.upcase.presence || "EUR"}"
  end

  def status_badge(status)
    variant = STATUS_BADGE_VARIANTS.fetch(status.to_s, "badge-gray")
    tag.span(status, class: "#{variant} capitalize")
  end

  EMAIL_KIND_LABELS = {
    "portal" => "Access link", "purchase" => "Receipt",
    "refund" => "Refund notice", "expiry" => "Expiry reminder"
  }.freeze

  def email_kind_label(kind)
    EMAIL_KIND_LABELS.fetch(kind.to_s, kind.to_s.humanize)
  end
end
