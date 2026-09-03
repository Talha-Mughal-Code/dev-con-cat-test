module Verification
  # Decides, before anything runs, what each layer's fate is.
  #
  # This is where the brief's three states are actually assigned, and where the
  # credit budget is reconciled with the layer list. Doing it up front - rather
  # than discovering mid-run that the account cannot afford layer nine - means
  # the run's shape is known and recorded before a single vendor is called, and
  # the live panel can show every layer's row immediately.
  #
  # BUDGETING
  # A run is planned in two waves. Wave 1 is the cheap, dispositive checks; wave
  # 2 is the expensive weighted signals. When an account cannot afford
  # everything, wave 1 is funded first: those are the layers that can reject a
  # lead outright, so they are worth strictly more per credit than the ones that
  # only shade a score.
  #
  # If even wave 1 is unaffordable the run halts rather than producing a partial
  # verdict, because a verdict from two of six dispositive checks is not a
  # verdict a buyer could defend.
  Plan = Struct.new(:module_key, :detection_module, :state, :wave, :cost, :runnable,
                    keyword_init: true)

  class Planner
    def initialize(lead:, account: nil, policy: nil)
      @lead = lead
      @account = account || lead.account
      @policy = policy || @account.active_consensus_policy
      @context = Engine::LeadContext.from(lead)
    end

    # Returns [plans, budget] where budget describes what could be afforded.
    def call
      plans = base_plans
      apply_budget!(plans)
      [ plans, budget_report(plans) ]
    end

    private

    attr_reader :lead, :account, :policy, :context

    def base_plans
      enabled_costs = account.enabled_module_costs

      DetectionModule.ordered.map do |mod|
        unless enabled_costs.key?(mod.key)
          # NOT ENABLED. The buyer did not pay for this layer. Not a pass, not a
          # failure, and it costs nothing.
          next Plan.new(module_key: mod.key, detection_module: mod, state: "not_enabled",
                        wave: mod.wave, cost: 0, runnable: false)
        end

        unless applicable?(mod)
          # NOT APPLICABLE. The layer is bought and working, but this lead is not
          # something it can speak to - the brief's example is a voice check on a
          # lead with no voice sample.
          next Plan.new(module_key: mod.key, detection_module: mod, state: "not_applicable",
                        wave: mod.wave, cost: 0, runnable: false)
        end

        Plan.new(module_key: mod.key, detection_module: mod, state: "pending",
                 wave: mod.wave, cost: enabled_costs.fetch(mod.key), runnable: true)
      end
    end

    # Applicability is asked of the evaluator, not guessed here, and it is asked
    # BEFORE the vendor is charged for. Voice is the case that matters: most
    # leads have no sample, and paying five credits to be told so would be
    # indefensible.
    #
    # It needs the vendor payload to answer, which for voice is a cheap lookup
    # of whether a sample exists. If that lookup itself fails we assume the layer
    # does apply and let the run record a proper errored state, rather than
    # silently marking it not-applicable and hiding a failure.
    def applicable?(mod)
      evaluator = Engine::Registry.for(mod.key)
      return true unless evaluator.method(:applicable?).owner != Engine::Evaluators::Base

      evaluator.applicable?(applicability_probe(mod.key), context)
    rescue Providers::LayerUnavailable
      true
    end

    def applicability_probe(module_key)
      @probes ||= {}
      @probes[module_key] ||= gateway.fetch(module_key) || {}
    end

    def gateway
      @gateway ||= Providers::Gateway.new(lead: lead, capture_session: lead.capture_session)
    end

    def apply_budget!(plans)
      available = account.credits_remaining
      runnable = plans.select(&:runnable)

      wave_one_cost = runnable.select { |p| p.wave == 1 }.sum(&:cost)
      total_cost = runnable.sum(&:cost)

      return if total_cost <= available

      if wave_one_cost > available
        # Cannot even fund the dispositive checks. Mark everything skipped; the
        # orchestrator turns this into a halted run with no verdict.
        runnable.each do |plan|
          plan.state = "skipped_insufficient_credits"
          plan.runnable = false
        end
        return
      end

      # Fund wave 1 in full, then wave 2 in ascending cost order so the buyer
      # gets as many voices as their remaining credits allow rather than one
      # expensive one.
      spend = wave_one_cost
      runnable.select { |p| p.wave == 2 }.sort_by(&:cost).each do |plan|
        if spend + plan.cost <= available
          spend += plan.cost
        else
          plan.state = "skipped_insufficient_credits"
          plan.runnable = false
        end
      end
    end

    def budget_report(plans)
      runnable = plans.select(&:runnable)
      skipped = plans.select { |p| p.state == "skipped_insufficient_credits" }

      {
        available: account.credits_remaining,
        estimated: runnable.sum(&:cost),
        full_stack_cost: plans.reject { |p| p.state.in?(%w[not_enabled not_applicable]) }.sum(&:cost),
        skipped_for_credits: skipped.map(&:module_key),
        # True when not even wave 1 could be funded. The run cannot produce a
        # defensible verdict, so it must halt rather than guess.
        halt: runnable.empty? && skipped.any?
      }
    end
  end
end
