# For the deal site's refunds: revoke a code by its plaintext, as the refund report lists it.
class Api::Admin::RedemptionCodesController < Api::Admin::BaseController
  def revoke
    code = RedemptionCode.find_by_code(params[:code])
    return head :not_found unless code

    code.revoke!
    license = code.license
    render json: { status: code.status, revoked_at: code.revoked_at,
      license: license && { id: license.id, status: license.status, max_activations: license.max_activations } }
  end
end
