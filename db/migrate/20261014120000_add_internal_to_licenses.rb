# A license the owner made for himself, to test the app. It keeps working like any other, but
# the trial and sales reports skip it. Not `test`, which is Kernel#test.
class AddInternalToLicenses < ActiveRecord::Migration[8.1]
  def change
    add_column :licenses, :internal, :boolean, default: false, null: false
  end
end
