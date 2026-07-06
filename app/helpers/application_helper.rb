module ApplicationHelper
  # Real photo when the customer has a Gravatar; a unique identicon otherwise.
  def gravatar_url(email, size: 40)
    hash = Digest::MD5.hexdigest(email.to_s.strip.downcase)
    "https://www.gravatar.com/avatar/#{hash}?d=identicon&s=#{size}"
  end

  STATUS_BADGE_COLORS = {
    "active" => "bg-green-50 text-green-700 ring-green-600/20",
    "expired" => "bg-amber-50 text-amber-700 ring-amber-600/20",
    "refunded" => "bg-red-50 text-red-700 ring-red-600/20",
    "inactive" => "bg-gray-100 text-gray-600 ring-gray-500/20",
  }.freeze

  def status_badge(status)
    colors = STATUS_BADGE_COLORS.fetch(status.to_s, STATUS_BADGE_COLORS["inactive"])
    tag.span(status,
      class: "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium capitalize ring-1 ring-inset #{colors}")
  end
end
