class Admin::ActivationsController < Admin::BaseController
  def index
    @activations = paginate(Activation.includes(license: [ :product, :customer ]).order(activated_at: :desc))
  end
end
