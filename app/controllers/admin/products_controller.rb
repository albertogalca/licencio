class Admin::ProductsController < Admin::BaseController
  before_action :set_product, only: [ :edit, :update ]

  def index
    @products = Product.order(:name)
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
        update_duration_days sender_email stripe_product_id
        loops_transactional_id loops_magic_link_transactional_id loops_api_key]
      permitted += %i[slug bundle_identifier license_prefix] if @product.nil? || @product.new_record?
      attrs = params.require(:product).permit(*permitted)
      attrs.delete(:loops_api_key) if attrs[:loops_api_key].blank? # blank = leave existing key
      attrs
    end
end
