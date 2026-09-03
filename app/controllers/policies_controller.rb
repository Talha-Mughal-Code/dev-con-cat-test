# The account's consensus policy: thresholds, weights, and which hard stops are
# armed.
#
# This screen is the answer to "how would a buyer tune the engine?" - the tuning
# is data, so it is editable here without a deploy. An account edits a copy; the
# platform default is never mutated from a tenant screen.
class PoliciesController < ApplicationController
  def show
    authorize! :view_policy

    with_tenant_scope do
      @policy = current_account.active_consensus_policy
      @inherited = @policy.platform_default?
      @hard_stops = Engine::HardStops::ALL
      @weights = ConsensusPolicy::DEFAULT_RULES.fetch("weights")
      @effective = effective_view(@policy)
    end
  end

  def update
    authorize! :manage_policy

    with_tenant_scope do
      @policy = account_policy
      @policy.rules = merged_rules(@policy)

      if @policy.save
        redirect_to policy_path, notice: "Policy saved as version #{@policy.version}."
      else
        @inherited = false
        @hard_stops = Engine::HardStops::ALL
        @weights = ConsensusPolicy::DEFAULT_RULES.fetch("weights")
        @effective = effective_view(@policy)
        flash.now[:alert] = @policy.errors.full_messages.to_sentence
        render :show, status: :unprocessable_entity
      end
    end
  end

  private

  # The first edit forks the platform default into an account-owned policy, so
  # a buyer's tuning cannot affect anyone else - and so the platform default
  # keeps reaching every account that has not deliberately diverged.
  def account_policy
    current_account.consensus_policies.where(active: true).order(version: :desc).first ||
      current_account.consensus_policies.new(
        name: "#{current_account.company_name} policy", version: 1, active: true, rules: {}
      )
  end

  def merged_rules(policy)
    rules = policy.rules.deep_dup
    submitted = params.require(:policy)

    if (thresholds = submitted[:thresholds])
      rules["thresholds"] = (rules["thresholds"] || {}).merge(
        "accept_below" => thresholds[:accept_below].to_f,
        "reject_at_or_above" => thresholds[:reject_at_or_above].to_f,
        "coverage_floor" => thresholds[:coverage_floor].to_f
      )
    end

    # Checkboxes: only the armed ones are submitted, so every known code is set
    # explicitly rather than inferred from absence.
    armed = Array(submitted[:hard_stops]).map(&:to_s)
    rules["hard_stops"] = Engine::HardStops::CODES.index_with do |code|
      { "enabled" => armed.include?(code) }
    end

    Array(submitted[:weights]).each do |module_key, conditions|
      next unless conditions.respond_to?(:each)

      conditions.each do |condition, value|
        next if value.blank?

        rules["weights"] ||= {}
        rules["weights"][module_key] ||= {}
        rules["weights"][module_key][condition] = value.to_f
      end
    end

    rules
  end

  # What the engine will actually use, default and override resolved together,
  # so the screen shows the effective policy rather than only the diff.
  def effective_view(policy)
    {
      thresholds: policy.thresholds,
      armed_hard_stops: policy.enabled_hard_stops,
      weights: ConsensusPolicy::DEFAULT_RULES.fetch("weights").keys.index_with do |module_key|
        policy.weights_for(module_key)
      end
    }
  end
end
