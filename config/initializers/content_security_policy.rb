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
    # No :https here — scripts/styles are self-hosted (importmap, Turbo, compiled
    # Tailwind); allowing any https origin would let an injected external <script> run
    # despite the nonce. The nonce covers our inline importmap + Turbo's inline styles.
    policy.script_src  :self
    policy.style_src   :self
  end

  # Nonce the inline importmap + inline scripts/styles so we don't need 'unsafe-inline'.
  # Tied to the session id so Turbo-cached pages keep a matching nonce across restores.
  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  config.content_security_policy_nonce_directives = %w[script-src style-src]
end
