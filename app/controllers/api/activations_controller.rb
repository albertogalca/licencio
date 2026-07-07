class Api::ActivationsController < Api::BaseController
  # The product API key ships inside the desktop binary, so cap the licensing endpoint to blunt
  # trial-token farming and key probing (checkout/products/recoveries are already capped).
  rate_limit to: 30, within: 1.minute, with: -> { head :too_many_requests }

  # hardware_id backs the seat identity; without it activate!/trial_for commit a license then 500
  # on the missing activation, orphaning a trial per request. Refuse up front.
  before_action :require_hardware_id

  def create
    license =
      if params[:license_key].present?
        @product.licenses.find_by!(license_key: params[:license_key])
      else
        @product.trial_for(hardware_id: params[:hardware_id]) or return render_api_error(:trial_unavailable)
      end
    if license.activatable?
      license.activate!(hardware_id: params[:hardware_id], device_name: params[:device_name])
      claims = license.token_claims(hardware_id: params[:hardware_id], nonce: params[:nonce])
      render json: { jwt: @product.sign_jwt(claims), public_key: @product.eddsa_public_key }
    else
      render_api_error(license_error_code(license))
    end
  end

  def destroy
    license = @product.licenses.find_by!(license_key: params[:license_key])
    if license.deactivate!(hardware_id: params[:hardware_id])
      head :no_content
    else
      render_api_error(:device_not_active)
    end
  end

  private
    def require_hardware_id
      render_api_error(:missing_hardware_id) if params[:hardware_id].blank?
    end

    # Distinguish why an inactive license was refused, so the client can message it.
    def license_error_code(license)
      return :license_expired if license.expired?
      { "expired" => :license_expired, "refunded" => :license_refunded }.fetch(license.status, :license_inactive)
    end
end
