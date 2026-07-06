class Admin::LicensesController < Admin::BaseController
  before_action :set_license, only: [ :edit, :update ]

  def index
    @licenses = License.includes(:product, :customer).order(created_at: :desc)
    @licenses = @licenses.where(product_id: params[:product_id]) if params[:product_id].present?
    @licenses = @licenses.where(status: params[:status]) if params[:status].present?
  end

  def new
    @license = License.new(status: "active")
  end

  def create
    @license = License.new(license_params)
    @license.customer = find_or_create_customer
    if @license.save
      redirect_to admin_licenses_path, notice: "License created: #{@license.license_key}"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @license.update(update_params)
      redirect_to admin_licenses_path, notice: "License updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_license
      @license = License.find(params[:id])
    end

    def license_params
      params.require(:license).permit(:product_id, :max_activations, :status, :expires_at)
    end

    def update_params
      params.require(:license).permit(:max_activations, :status, :expires_at)
    end

    def find_or_create_customer
      email = params.dig(:license, :customer_email).to_s.strip
      Customer.find_or_create_by(email: email) if email.present?
    end
end
