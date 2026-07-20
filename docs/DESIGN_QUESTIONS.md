# Design Questions — answer these in `SOLUTION.md`

These are the judgement calls we care about. Short answers are fine; we want
your *reasoning*, not essays. There are no single right answers.

## Domain modeling
1. What are your core models and how do leads, layer-results, verdicts, and
   certificates relate? Where does a "verification run" live?
2. A layer can be **not-enabled**, **not-applicable**, or **returned-a-verdict**.
   How does your schema keep these distinct?

## Consensus engine
3. Which layers are **hard stops** vs **weighted signals**, and why?
4. How do you turn N layer results into `ACCEPT / REVIEW / REJECT` + a reason?
   Weights? Thresholds? Rules? Show the shape.
5. What happens when a required layer is **unavailable** or errors mid-run — does
   the lead fail open or fail closed?
6. How would a buyer *tune* the engine (e.g. treat "suspected litigator" as a
   hard stop)? Is your policy data or code?

## Multi-tenancy & authorization
7. How do you guarantee an account never sees another account's leads,
   certificates, or CRM — at the query layer, not just the UI?
8. How is `super_admin` different, and how do you keep that power from leaking?

## Credits & subscriptions
9. When exactly is a credit consumed — per lead, per layer, per run? What's your
   reasoning?
10. What happens when an account hits **zero credits mid-verification**? What
    does the super-admin dashboard show, and how early does it warn?

## Consent certificates
11. What goes *in* a certificate so a buyer could defend the lead later? How do
    you make it tamper-evident / verifiable?

## Real-time & jobs
12. Sync or background jobs for the layer calls? Why?
13. Which real-time transport did you pick for the live landing page, and what
    did you trade away?

## If you had another week
14. What's the first thing you'd build next, and what's the biggest risk in your
    current design?
