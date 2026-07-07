class Activation < ApplicationRecord
  belongs_to :license

  scope :active, -> { where(deactivated_at: nil) }
  scope :provisional, -> { where(provisional: true) }

  validates :hardware_id, :activated_at, presence: true

  def deactivate!
    update!(deactivated_at: Time.current) unless deactivated_at
  end
end
