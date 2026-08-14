class Api::PublicController < ActionController::API
  # Machine-readable error contract for the desktop clients: every failure carries a
  # stable `code` plus a human `error` string, so a client can tell "expired" from
  # "refunded" from "seats full" instead of guessing at a bare status.
  ERRORS = {
    unauthorized:       [ :unauthorized, "Invalid or missing API key." ],
    license_not_found:  [ :not_found,    "No license matches that key for this product." ],
    license_expired:    [ :forbidden,    "This license has expired." ],
    license_refunded:   [ :forbidden,    "This license was refunded." ],
    license_inactive:   [ :forbidden,    "This license is not active." ],
    # A real, live license that still doesn't grant what was asked for — a trial key
    # against the unlock endpoint, where "not active" would be an outright lie.
    license_not_eligible: [ :forbidden,  "That license doesn't unlock this app." ],
    seat_limit_reached: [ :conflict,     "All seats for this license are in use." ],
    trial_unavailable:  [ :forbidden,    "No trial is available for this product." ],
    price_not_found:    [ :not_found,    "That price is no longer available." ],
    device_not_active:  [ :not_found,    "That device is not currently active." ],
    missing_hardware_id: [ :unprocessable_entity, "A hardware_id is required." ],
    not_academic_email: [ :unprocessable_entity, "That isn't a school address I recognise." ],
    student_discount_unavailable: [ :service_unavailable, "Student pricing isn't set up for this product." ],
    product_not_found:  [ :not_found,    "No product matches that name." ],
    # Unlock flow. These are read by a person, inside the app, at the one moment they're
    # trying to get in — so each says what happened AND what to do next. There are no
    # accounts here, only a purchase and an inbox, so the wording never implies one, and
    # never says whether an address has bought anything.
    invalid_email:      [ :unprocessable_entity,
                          "That doesn't look like an email address. Check it for a typo and try again." ],
    # Also the answer when there's no live code at all (spent, or never issued), which is
    # why it offers a fresh one as well as a re-read of the digits.
    code_invalid:       [ :unprocessable_entity,
                          "Those six digits don't match the code I emailed. Check them and try again, " \
                          "or ask for a new code." ],
    code_expired:       [ :gone,
                          "Codes last 10 minutes, and this one has run out. Ask for a new one and " \
                          "I'll email it straight away." ],
    too_many_attempts:  [ :too_many_requests,
                          "That code has been tried too many times, so it no longer works. Ask for a " \
                          "new one to start over." ],
    # Factual, not accusatory: it states what the record says and offers a way to correct it.
    purchase_refunded:  [ :forbidden,
                          "This Cozy license was refunded, so it no longer unlocks the app. Reply to " \
                          "your purchase receipt if that isn't right." ],
    purchase_not_found: [ :not_found,
                          "I can't find a Cozy license for that email address. If you bought with a " \
                          "different one, try that address — or reply to your receipt and I'll sort it out." ]
  }.freeze

  rescue_from ActiveRecord::RecordNotFound, with: -> { render_api_error(:license_not_found) }

  private
    def render_api_error(code)
      status, message = ERRORS.fetch(code)
      render json: { error: message, code: }, status:
    end
end
