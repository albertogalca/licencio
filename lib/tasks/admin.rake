namespace :admin do
  desc "Create an admin user: rake admin:create[email,password]"
  task :create, [ :email, :password ] => :environment do |_, args|
    admin = AdminUser.create!(email: args[:email], password: args[:password])
    puts "Created admin #{admin.email}"
  end
end
