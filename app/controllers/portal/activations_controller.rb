class Portal::ActivationsController < Portal::BaseController
  def destroy
    current_customer.activations.active.find(params[:id]).deactivate!
    redirect_to portal_root_path, notice: "Device deactivated. The seat is free again."
  end
end
