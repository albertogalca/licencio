class Admin::ActivationsController < Admin::BaseController
  def index
    @activations = Activation.includes(license: [ :product, :customer ]).order(activated_at: :desc)
  end
end
