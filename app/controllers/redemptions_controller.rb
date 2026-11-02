# Where a deal-site buyer (AppSumo) turns a code into a license. Public: the code is the
# credential. Shares the portal's look, and ?product=<slug> brands the page before anything
# is typed, the way recoveries does.
class RedemptionsController < Portal::BaseController
  skip_before_action :require_customer

  # Codes are ~79 bits, so these never stop a guess; they stop a script from using this page
  # to send mail. Named, or the two would share one counter.
  rate_limit to: 20, within: 1.hour, only: :create, name: "redeem-ip",
    with: -> { refuse("Too many attempts. Wait an hour, then try again.", status: :too_many_requests) }
  rate_limit to: 10, within: 1.hour, only: :create, name: "redeem-email",
    by: -> { params[:email].to_s.strip.downcase },
    with: -> { refuse("Too many attempts. Wait an hour, then try again.", status: :too_many_requests) }

  def new
    @product = Product.matching(params[:product]).first if params[:product].present?
  end

  def create
    email = params[:email].to_s.strip.downcase
    unless email.match?(Api::PublicController::EMAIL_SHAPE)
      return refuse("That doesn't look like an email address. Check it for a typo.")
    end

    @code = RedemptionCode.redeem!(params[:code], email:)
    @license = @code.license
    @product = @license.product
    # Rendered, not redirected: the key stays out of every URL and every log line.
    render :show
  rescue RedemptionCode::Invalid
    refuse("That code isn't valid, or it was already used. Check it and try again.")
  rescue RedemptionCode::StackLimitReached => error
    refuse("This email already has #{error.limit} codes on its license, and that is the most one " \
      "license can take. Your code was not used.")
  end

  private
    def refuse(message, status: :unprocessable_entity)
      @product ||= Product.matching(params[:product]).first if params[:product].present?
      @email = params[:email].to_s.strip
      flash.now[:alert] = message
      render :new, status:
    end
end
