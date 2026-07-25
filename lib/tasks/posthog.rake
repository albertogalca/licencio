# Backfills purchase_completed into PostHog for sales that happened while the emitter was
# missing. Payments moved from Lemon Squeezy to Stripe on 2026-07-08 and nothing replaced the
# Lemon Squeezy worker, so the last event fired 2026-07-09 and every sale after it went
# unrecorded while buy_clicked kept firing.
#
#   DRY_RUN=1 SINCE=2026-07-09 bin/rails posthog:backfill_purchases   # report only
#             SINCE=2026-07-09 bin/rails posthog:backfill_purchases   # actually send
#
# PRODUCT_SLUG defaults to picmal. NOT idempotent: PostHog has no practical event delete, so a
# second run double-counts revenue. Dry-run first, run once, check the funnel.
namespace :posthog do
  desc "Backfill purchase_completed events into PostHog for a past window"
  task backfill_purchases: :environment do
    slug    = ENV.fetch("PRODUCT_SLUG", "picmal")
    since   = Date.parse(ENV.fetch("SINCE")).beginning_of_day
    until_  = ENV["UNTIL"].present? ? Date.parse(ENV["UNTIL"]).end_of_day : Time.current
    dry_run = ENV["DRY_RUN"].present?

    product = Product.find_by!(slug:)
    abort "#{slug} has no PostHog API key set" if product.posthog_api_key_or_default.blank?
    stripe_opts = { api_key: product.stripe_secret_key }

    # The payments ledger, not Stripe's session list: these are the sales licencio actually
    # fulfilled for THIS product, so a shared Stripe account can't leak another product's revenue in.
    payments = Payment.joins(:license).where(licenses: { product_id: product.id })
      .where(created_at: since..until_).order(:created_at)

    puts "#{payments.count} payment(s) for #{slug} between #{since.to_date} and #{until_.to_date}"
    sent = attributed = eligible = 0

    payments.each do |payment|
      # $0 payments are BundleHunt rows, press comps, and admin-issued licenses, never web
      # checkouts, which is why none of them carry a client_reference_id. Emitting them would
      # leave revenue right and inflate purchase count and visit-to-purchase rate several times
      # over. INCLUDE_ZERO=1 to send them anyway.
      if payment.amount_cents.to_i.zero? && ENV["INCLUDE_ZERO"].blank?
        puts "  #{payment.created_at.to_date} skip $0 (comp/bundle/manual): #{payment.license.customer&.email}"
        next
      end

      # client_reference_id is the browser's PostHog distinct_id and lives only on the Stripe
      # session, never copied into our ledger. Without it the sale still counts as revenue,
      # it just can't join the pageview funnel.
      session = Stripe::Checkout::Session.list({ payment_intent: payment.stripe_payment_intent, limit: 1 }, stripe_opts).data.first
      distinct_id = session && session[:client_reference_id]
      email = session&.customer_details&.email || payment.license.customer&.email

      if email.blank?
        warn "  skip #{payment.stripe_payment_intent}: no email on session or customer"
        next
      end

      eligible += 1
      attributed += 1 if distinct_id.present?
      puts "  #{payment.created_at.to_date} #{email} #{payment.amount_cents.to_i / 100.0} #{payment.currency} " \
           "#{distinct_id.present? ? "-> #{distinct_id}" : '(unattributed)'}"
      next if dry_run

      PosthogPurchaseJob.perform_now(product, distinct_id:, email:,
        amount_cents: payment.amount_cents, currency: payment.currency,
        timestamp: payment.created_at)
      sent += 1
    end

    skipped = payments.count - eligible
    puts dry_run ? "DRY RUN: nothing sent. #{eligible} would be sent (#{attributed} attributed), #{skipped} skipped." :
                   "Sent #{sent} event(s), #{attributed} attributed to a web session, #{skipped} skipped."
  end
end
