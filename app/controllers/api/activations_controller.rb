class Api::ActivationsController < Api::BaseController
  def create
    license =
      if params[:license_key].present?
        @product.licenses.find_by!(license_key: params[:license_key])
      else
        @product.trial_for(hardware_id: params[:hardware_id]) or return head :forbidden
      end
    if license.active?
      license.activate!(hardware_id: params[:hardware_id], device_name: params[:device_name])
      claims = license.token_claims(hardware_id: params[:hardware_id], nonce: params[:nonce])
      render json: { jwt: @product.sign_jwt(claims), public_key: @product.eddsa_public_key }
    else
      head :forbidden
    end
  end

  def destroy
    license = @product.licenses.find_by!(license_key: params[:license_key])
    if license.deactivate!(hardware_id: params[:hardware_id])
      head :no_content
    else
      head :not_found
    end
  end
end
