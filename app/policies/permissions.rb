# What each role may do.
#
# One object rather than a policy class per model, because the rules here are
# genuinely role-shaped: there are three roles and about a dozen verbs, and the
# decisions almost never depend on the individual record. A per-model policy
# hierarchy would be more ceremony carrying the same information.
#
# Where a record IS relevant, it is checked - see the account_id assertions
# below. Those are belt-and-braces: the tenant scope already makes another
# account's record unloadable, so a policy check that fires on ownership means
# something has gone wrong upstream, and it should fail loudly rather than be
# assumed impossible.
class Permissions
  # A platform operator reads across accounts and changes nothing inside them.
  # No verb here grants writing tenant data, which is the answer to "how do you
  # keep super_admin's power from leaking": there is nothing to leak, because
  # the capability was never granted.
  SUPER_ADMIN = %i[
    view_platform view_any_account view_admin_log
  ].freeze

  # Day-to-day work: read the CRM, read activity, read certificates.
  MEMBER = %i[
    view_dashboard view_leads view_lead view_activity view_certificate
    verify_certificate view_pixels
  ].freeze

  # Everything a member can do, plus configuration and money.
  ACCOUNT_ADMIN = (MEMBER + %i[
    manage_pixels create_pixel edit_pixel view_users manage_users
    view_billing view_policy manage_policy reverify_lead
  ]).freeze

  def initialize(user)
    @user = user
  end

  def allow?(action, record = nil)
    return false if user.nil?

    action = action.to_sym
    return false unless verbs.include?(action)
    return false unless record_in_scope?(record)

    true
  end

  def verbs
    case user&.role
    when "super_admin"    then SUPER_ADMIN
    when "account_admin"  then ACCOUNT_ADMIN
    when "member"         then MEMBER
    else []
    end
  end

  private

  attr_reader :user

  # If a record ever reaches a permission check while belonging to another
  # account, the query layer has failed. Deny, so the failure is visible rather
  # than silently tolerated.
  def record_in_scope?(record)
    return true if record.nil?
    return false if user.super_admin? # operators read through Platform:: only
    return true unless record.respond_to?(:account_id)

    record.account_id == user.account_id
  end
end
