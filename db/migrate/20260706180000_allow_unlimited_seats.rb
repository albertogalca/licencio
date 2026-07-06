class AllowUnlimitedSeats < ActiveRecord::Migration[8.0]
  # nil max_activations = unlimited seats (e.g. Cozy). Existing rows keep their integer caps.
  def change
    change_column_null :licenses, :max_activations, true
    change_column_null :products, :max_activations_default, true
    change_column_default :products, :max_activations_default, from: 3, to: nil
  end
end
