# Regional pricing. A license keeps the band it was bought at, and renews and upgrades at it.
# nil is a license sold before bands, which renews by the rules it was sold under. Each payment
# records the country the site vouched for and the country the card was issued in, so a VPN to a
# cheaper band shows up as a mismatch. The token secret is shared with the marketing site.
class AddRegionalBands < ActiveRecord::Migration[8.1]
  def change
    add_column :licenses, :regional_band, :integer
    add_column :payments, :regional_country, :string
    add_column :payments, :card_country, :string
    add_column :products, :region_token_secret, :string
  end
end
