require "io/console"

namespace :admin do
  desc "Create an admin user: rake admin:create[email] (password read from a hidden prompt)"
  task :create, [ :email ] => :environment do |_, args|
    email = args[:email].presence || $stdin.getpass("Email: ").strip
    # Read from a hidden prompt so the password never lands in shell history / the process list.
    password = $stdin.getpass("Password: ")
    admin = AdminUser.create!(email: email, password: password)
    puts "Created admin #{admin.email}"
  end
end
