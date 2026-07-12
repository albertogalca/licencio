class AddLoopsMailingListIdToProducts < ActiveRecord::Migration[8.1]
  # Nullable: blank → buyers aren't added to any Loops mailing list (current behaviour).
  # Set to a Loops list id (e.g. Picmal Newsletter) to auto-add buyers on purchase.
  def change
    add_column :products, :loops_mailing_list_id, :string
  end
end
