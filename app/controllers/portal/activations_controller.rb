class Portal::ActivationsController < Portal::BaseController
  def destroy
    # Scoped to the session's product AND customer — a Cozy session only touches Cozy devices.
    activation = current_product.activations.active
      .where(licenses: { customer_id: current_customer.id }).find_by(id: params[:id])
    if activation
      activation.deactivate!
      redirect_to portal_root_path, notice: "Device deactivated. The seat is free again."
    else
      redirect_to portal_root_path, alert: "That device could not be found."
    end
  end
end
