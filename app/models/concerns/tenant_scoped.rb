# Mixed into every model that belongs to a tenant. See TenantScope for the
# reasoning behind enforcing isolation with a default scope.
module TenantScoped
  extend ActiveSupport::Concern

  included do
    belongs_to :account

    default_scope { TenantScope.relation_for(self) }
  end
end
