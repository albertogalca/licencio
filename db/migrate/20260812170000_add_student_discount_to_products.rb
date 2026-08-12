class AddStudentDiscountToProducts < ActiveRecord::Migration[8.1]
  def change
    # Both must be set for /api/students/discount to do anything (Product#student_discount?):
    # the Loops template that carries the code, and the Stripe promotion code itself.
    add_column :products, :student_transactional_id, :string
    add_column :products, :student_discount_code, :string
  end
end
