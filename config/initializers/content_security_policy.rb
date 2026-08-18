# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :https, :data # :https covers Gravatar avatars
    policy.object_src  :none
    # None of these fall back to default_src, so they have to be stated. base_uri is the one
    # that matters most: an injected <base> retargets every relative script URL and defeats the
    # nonce. form_action needs Stripe: Chrome applies it to the redirect that FOLLOWS a form
    # post, so the renew/upgrade forms' 303 to Stripe Checkout is blocked under bare :self.
    policy.base_uri        :self
    policy.form_action     :self, "https://checkout.stripe.com"
    policy.frame_ancestors :none
    # No :https here — scripts/styles are self-hosted (importmap, Turbo, compiled
    # Tailwind); allowing any https origin would let an injected external <script> run
    # despite the nonce. The nonce covers our inline importmap + Turbo's inline styles.
    policy.script_src  :self
    policy.style_src   :self
  end

  # Nonce the inline importmap + inline scripts/styles so we don't need 'unsafe-inline'.
  # Tied to the session id so Turbo-cached pages keep a matching nonce across restores.
  # Random per request, not request.session.id: a visitor with no session yet (the recovery
  # page) has no id, and an empty nonce silently drops every <style> block we emit. Nothing
  # here caches HTML, which is the only reason to want a stable nonce.
  config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src style-src]
end
