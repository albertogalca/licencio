class Admin::ActivationsController < Admin::BaseController
  def index
    @activations = paginate(Activation.includes(license: [ :product, :customer ]).order(activated_at: :desc))
  end

  def destroy
    activation = Activation.active.find(params[:id])
    activation.deactivate!
    redirect_back fallback_location: edit_admin_license_path(activation.license),
      notice: "Device deactivated. The seat is free again."
  end
end
