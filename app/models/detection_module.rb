# Catalog of the detection layers the platform can run. Seeded from
# mock-data/accounts.json's module_costs_in_credits plus the descriptions in
# docs/provider-modules.md.
class DetectionModule < ApplicationRecord
  has_many :account_modules, dependent: :destroy
  has_many :accounts, through: :account_modules
  has_many :layer_results, dependent: :restrict_with_error

  validates :key, presence: true, uniqueness: true
  validates :name, presence: true
  validates :wave, inclusion: { in: [ 1, 2 ] }

  scope :ordered, -> { order(:position, :key) }
  scope :wave, ->(n) { where(wave: n) }

  def to_param = key
end
