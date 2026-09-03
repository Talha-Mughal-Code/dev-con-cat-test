# Tenant isolation, enforced where it cannot be forgotten: in the SQL.
#
# Every tenant-owned table carries a NOT NULL account_id, and every model that
# owns one applies a default scope built here. The consequence is that
# `Lead.find(id)` for another account's lead raises RecordNotFound rather than
# returning the row - there is no code path, controller bug, or crafted
# parameter that produces a cross-tenant read, because the predicate is not
# optional.
#
# The two contexts that legitimately span accounts are explicit and auditable:
#
#   TenantScope.across_accounts { ... }   # platform operator reads, job bootstrap
#   TenantScope.for_account(acct) { ... } # act as one specific account
#
# Missing context RAISES rather than returning everything. A screen that forgets
# to establish an account fails loudly in development and returns a 500 in
# production; the alternative default - `all` - would silently leak every
# tenant's data, which is the exact failure this design exists to prevent.
module TenantScope
  class MissingTenantContext < StandardError; end

  class << self
    def relation_for(klass)
      return klass.unscoped.all if Current.tenant_bypass

      account_id = Current.account_id
      unless account_id
        raise MissingTenantContext, <<~MSG.squish
          #{klass.name} was queried with no tenant context. Establish one with
          TenantScope.for_account(account) { ... }, or - for a platform-operator
          read - opt in explicitly with TenantScope.across_accounts { ... }.
        MSG
      end

      klass.unscoped.where(account_id: account_id)
    end

    # Run a block with the tenant predicate lifted. Only reachable from
    # Platform:: controllers (which require super_admin and write an audit log)
    # and from ApplicationJob while it loads the record that tells it which
    # account it is working for.
    def across_accounts
      previous = Current.tenant_bypass
      Current.tenant_bypass = true
      yield
    ensure
      Current.tenant_bypass = previous
    end

    def for_account(account)
      previous_account = Current.account
      previous_bypass  = Current.tenant_bypass
      Current.account = account
      Current.tenant_bypass = false
      yield account
    ensure
      Current.account = previous_account
      Current.tenant_bypass = previous_bypass
    end
  end
end
