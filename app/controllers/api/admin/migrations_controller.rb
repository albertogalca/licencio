require "csv"

class Api::Admin::MigrationsController < Api::Admin::BaseController
  def import
    if License.migration_sources.key?(params[:source])
      render json: License.import(parsed_rows, source: params[:source])
    else
      head :unprocessable_entity
    end
  end

  private
    def parsed_rows
      if request.content_type&.include?("csv")
        CSV.parse(request.body.read, headers: true).map(&:to_h)
      else
        params.require(:licenses).map(&:to_unsafe_h)  # trusted admin input, arbitrary row shape
      end
    end
end
