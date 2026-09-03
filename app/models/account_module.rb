class AccountModule < ApplicationRecord
  include TenantScoped

  belongs_to :detection_module

  validates :detection_module_id, uniqueness: { scope: :account_id }

  delegate :key, to: :detection_module

  def cost_in_credits
    cost_override || detection_module.default_cost_in_credits
  end
end
