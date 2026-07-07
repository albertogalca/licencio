class Admin::EmailsController < Admin::BaseController
  def create
    license = License.find(params[:license_id])
    if license.redeliver_email_later(params[:kind])
      redirect_to edit_admin_license_path(license),
        notice: "#{helpers.email_kind_label(params[:kind])} email queued for #{license.customer.email}."
    else
      redirect_to edit_admin_license_path(license), alert: "That email can't be sent for this license."
    end
  end
end
