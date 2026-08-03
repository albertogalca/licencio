class Admin::ProductsController < Admin::BaseController
  before_action :set_product, only: [ :edit, :update ]

  def index
    @products = paginate(Product.order(:name))
  end

  def new
    @product = Product.new(max_activations_default: 3, update_policy: "lifetime")
  end

  def create
    @product = Product.new(product_params)
    if @product.save
      redirect_to edit_admin_product_path(@product), notice: "Product created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @product.update(product_params)
      redirect_to edit_admin_product_path(@product), notice: "Product updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_product
      @product = Product.find(params[:id])
    end

    # slug / bundle_identifier / license_prefix are baked into issued license keys —
    # only settable on create. eddsa_private_key & api_key never come from the form.
    def product_params
      permitted = %i[name update_policy current_version max_activations_default trial_days
        update_duration_days renewal_stripe_price_id sender_email stripe_product_id stripe_secret_key stripe_webhook_secret
        checkout_success_url checkout_cancel_url download_url loops_transactional_id purchase_transactional_id
        refund_transactional_id expiry_reminder_transactional_id loops_api_key loops_mailing_list_id
        affiliate_landing_url affiliate_transactional_id affiliate_commission_percent
        logo_url accent_color background_color]
      permitted += %i[slug bundle_identifier license_prefix] if @product.nil? || @product.new_record?
      attrs = params.require(:product).permit(*permitted)
      # blank secret = leave existing key untouched
      %i[loops_api_key stripe_secret_key stripe_webhook_secret].each do |k|
        attrs.delete(k) if attrs[k].blank?
      end
      attrs
    end
end
