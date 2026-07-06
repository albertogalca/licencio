require "test_helper"

class AdminUserTest < ActiveSupport::TestCase
  test "authenticates with the right password" do
    admin = admin_users(:alberto)
    assert admin.authenticate("secret123")
    assert_not admin.authenticate("wrong")
  end

  test "normalizes and requires a unique email" do
    AdminUser.create!(email: "New@Licencio.example ", password: "pw")
    assert AdminUser.exists?(email: "new@licencio.example")

    dup = AdminUser.new(email: "admin@licencio.example", password: "pw")
    assert_not dup.valid?
  end
end
