# Super Pixel — solution notes

A multi-tenant Rails platform behind a single embeddable pixel. Each lead is run
through eleven fraud and consent detection layers, a consensus engine turns
their voices into one defensible verdict, and a signed consent certificate is
issued as evidence.

**181 tests, 648 assertions, all passing.** ~6,200 lines of Ruby, ~1,600 of ERB,
325 of pixel JavaScript, 19 tables.

---

## 1. How to run it

Requires Ruby 3.1+ and nothing else — no Postgres, no Redis.

```bash
bundle install
bin/rails db:prepare   # creates both SQLite databases (app + job queue)
bin/rails db:seed      # loads all five mock-data files, then verifies the 12 leads
bin/dev                # starts Puma and the Solid Queue worker together
```

Then open **<http://localhost:3000/demo>** — the wired landing page — or sign in
at <http://localhost:3000/login>.

Every seeded user's password is `super-pixel-demo-2026`. (`users.json` ships
`placeholder_password` values with an explicit instruction not to ship them
as-is, so they are ignored; override with `SEED_PASSWORD=…`.)

| Sign in as | Role | What it shows |
|---|---|---|
| `admin@catchingconsent.example` | super_admin | Platform overview: all accounts, burn rates, who's about to run dry |
| `dana@solarpro.example` | account_admin | Full account: CRM, pixels, policy editor |
| `luis@solarpro.example` | member | Read-only — try `/pixels/new` or `/policy` and get a 404 |
| `chris@autoinsure.example` | account_admin | The past-due account, 54 credits from empty |

```bash
bin/rails test                     # the whole suite
bin/rails leads:reconcile_credits  # prove the credit cache matches the ledger
LEAD=L-1009 bin/rails leads:reverify
SUPER_PIXEL_OUTAGES=trustedform,dnc bin/dev   # demo fail-closed on a live system
```

### Seeing the pixel work

**Same-origin:** `/demo` renders the funnel with a real `data-pixel-id` and
`data-endpoint`. Fill the form and the panel streams the actual layer results.

**Cross-origin** (the more interesting one, since a pixel's real job is running
on someone else's domain — this exercises CORS, the origin allowlist and the
capture token for real):

```bash
python3 -m http.server 3001 -d examples   # then open http://localhost:3001/landing-page.html
```

Things worth trying on the form — the mock vendors recognise a contact by phone
and email, the way a real vendor does, not by our internal lead id:

| Input | Result |
|---|---|
| Leave the defaults | `ACCEPT` — all ten layers pass |
| `+1 818 555 0199` (Robert Vance) | `REJECT` — confirmed TCPA litigator, hard stop |
| `+1 602 555 0120` | `REJECT` — DNC listed |
| `anything@mail-tempz.example` | `REJECT` — disposable domain, bot confirmed |
| Submit in under 1.5s | `REJECT` — the pixel's own first-party layer |
| Untick the consent box | `REVIEW` — consent declined |
| Submit the same person twice | `REJECT` — duplicate of the lead the first submission put in the CRM |

That last one is the whole loop closing: an accepted lead is written into the
buyer's CRM, so the second submission is caught against it.

---

## 2. Data model

19 tables. The shape that matters:

```
Account ─┬─ User                        (role: super_admin | account_admin | member)
         ├─ AccountModule ── DetectionModule     which layers this buyer pays for
         ├─ ConsensusPolicy                      thresholds/weights as DATA
         ├─ Pixel ─── CaptureSession             page load, visit IP, telemetry
         ├─ CrmRecord                            duplicate detection reads this
         ├─ CreditLedgerEntry                    append-only, immutable
         ├─ ActivityEvent                        timeline + audit + SSE cursor
         └─ Lead ─── VerificationRun ─┬─ LayerResult      (one per layer)
                                      └─ ConsentCertificate
```

### Where a "verification run" lives — and why it's not the lead

`VerificationRun` is one evaluation of one lead under one policy version. It is a
separate entity because **re-verification is a real requirement, not a
hypothetical**: after a vendor outage, after a policy change, or after an account
tops up following a halted run. The verdict belongs to the run; the lead just
points at the latest one via `current_verification_run_id`. History is preserved
and a certificate already relied upon stays valid.

### The three layer states

The brief calls this out three times, so it is two columns with a database
constraint tying them together:

- **`state`** — did this layer get to speak? `pending`, `completed`,
  `not_enabled`, `not_applicable`, `errored`, `timed_out`,
  `skipped_insufficient_credits`, `skipped_hard_stop`
- **`signal`** — what did it say? `pass`, `warn`, `fail`, `info`, and **`NULL`
  unless `state = 'completed'`**

```sql
CHECK ((state =  'completed' AND signal IS NOT NULL) OR
       (state <> 'completed' AND signal IS NULL))
```

Conflating them is the classic bug in this domain: a layer nobody paid for and a
layer that came back clean both end up looking like "no problem found", and the
certificate then implies a check that never happened. The constraint makes that
unrepresentable rather than merely discouraged.

### Invariants in the database, not just in Ruby

| Constraint | What it prevents |
|---|---|
| `verdict IS NOT NULL` only when `status = 'completed'` | A halted or errored run ever looking like an ACCEPT |
| `state = 'completed' OR credits_charged = 0` | Billing a buyer for a layer that did not answer |
| `super_admin` ⟺ `account_id IS NULL` | A mis-seeded user inheriting the platform-operator scope |
| Triggers on `consent_certificates` | Rewriting an issued signed body, even from a console |
| Triggers on `credit_ledger_entries` | Any `UPDATE` or `DELETE` on the billing record of truth |

This is why the project uses the **SQL schema format**: Rails' Ruby schema dumper
cannot express a trigger, so with `:ruby` the test database would silently lack
the guarantees the migrations exist to create — and a test asserting
immutability would pass against a database that had none.

### Layer boundaries

```
app/domain/engine/     pure consensus logic — no ActiveRecord, no I/O
app/domain/providers/  the vendor boundary — fixtures / derived responses
app/domain/sse/        the event-stream tailer
app/services/          orchestration spanning models
app/policies/          authorization
app/models/            persistence + invariants
```

The seam that matters most: **`app/domain/engine` never touches ActiveRecord and
never performs I/O.** It takes a raw payload plus a plain lead snapshot and
returns value objects. That is what makes the 20-point engine testable without a
database, a queue or a seed run — and explainable in an interview without
opening a controller.

A second seam inside it: **evaluators translate, consensus aggregates.** An
evaluator knows vendor semantics ("Anura `bad` means confirmed bot") and nothing
about thresholds; consensus knows thresholds and nothing about vendors. Findings
are the policy-free currency between them. Adding a twelfth vendor is one new
evaluator and one seed row; changing how strictly the platform judges touches
neither.

---

## 3. The consensus engine

### Hard stops vs weighted signals

The test I applied: **a hard stop is a condition where no amount of
countervailing evidence makes the lead purchasable.** That test is why the list
is eight items long and why "Anura says suspect" is not on it.

| Hard stop | Why it is dispositive |
|---|---|
| `litigator_confirmed` | A phone tied to 14 filed TCPA complaints is not a lead, it is a lawsuit with a dial tone |
| `dnc_listed` / `callback_window_closed` | If you cannot legally dial it, its value to a buyer of callable leads is zero |
| `consent_unverifiable` | The entire product is provable consent |
| `duplicate_hard` | Commercial: the buyer already owns this record |
| `bot_confirmed` | Anura `bad` arrives with explicit rule ids at 0.99 — a determination, not a suspicion. There is no consumer to consent |
| `voice_fraud` | One voiceprint under four identities is identity fraud on the one channel where it is provable |
| `litigator_suspected` | **Ships disarmed** — an unconfirmed pattern match, so by default a 0.30 weighted signal |

### Code vs data — and the tuning question

The **vocabulary** of hard stops is code (`Engine::HardStops`), because each
encodes a legal or economic claim that must be reviewable in a diff and
impossible to express malformedly through a settings screen. **Which are armed,
every weight, and every threshold is data** in a `consensus_policies.rules`
document, editable at `/policy`.

So the brief's own example — "treat suspected litigator as a hard stop" — is one
boolean, no deploy.

And a detail I am pleased with: **disarming a hard stop does not make it free.**
It falls back to a 0.65 weight — still above the reject threshold, so it rejects
on its own, but now combinable with and overridable by other evidence. That is
precisely the semantic difference between *dispositive* and *very heavy*.

### The arithmetic

**Within a layer: the maximum contribution, not the sum.** A layer is one voice
and gets one vote at the weight of its strongest objection. An email address that
is both disposable *and* undeliverable *and* high-fraud-score is three correlated
observations from one source, not three independent ones — summing them (0.35 +
0.30 + 0.15) would reject, taking the max gives 0.35 and a review. It also
removes any incentive to game the weights by splitting one condition into three.

**Across layers: noisy-OR.**

```
risk = 1 − Π(1 − contributionᵢ)
```

Chosen over a weighted sum for three reasons. It is the probabilistic reading of
the brief's own metaphor — independent imperfect detectors each raising doubt. It
**saturates correctly**: two 0.35 signals give 0.58, not 0.70, so a second
dissenting voice matters but cannot mechanically add its way past a threshold.
And it is **order-independent**, which matters when layers land as background
jobs complete in whatever order.

```
ACCEPT   risk < 0.20
REVIEW   0.20 ≤ risk < 0.60
REJECT   risk ≥ 0.60   (or any armed hard stop, which bypasses the score)
```

- **0.20** sits just above the largest advisory-only signal (a soft duplicate at
  0.15), so one commercial flag alone cannot deny an otherwise clean lead — but
  that flag plus *any* other doubt tips into REVIEW.
- **0.60** rather than a bare majority, so three moderate, partly-correlated
  objections (~0.50) still get a human look. Discarding a good lead costs real
  money; a second look costs a minute.

### The soft-duplicate decision

The design call I'd most want to discuss.

Lead **L-1012** is clean and high-value, and shares a phone with a CRM record
from three hours earlier under a different email. The brief hints `ACCEPT` while
also saying a good solution "surfaces this for human review rather than
auto-rejecting".

Rather than tune a weight to hit the hint, the resolution is that **a soft
duplicate is not a fraud signal at all — it is a commercial one.** "Is this
person real and legally contactable?" and "should you pay for this record again?"
are different questions with different consequences. So it is priced at 0.15,
below the accept threshold, and surfaced as an advisory on the run and in the
CRM. Alone it flags and accepts. Combined with any other doubt it reviews. No
special-casing — the threshold placement does it, and a test proves both halves.

### Unavailable layers: fail open, fail closed, never fail to reject

Which layers fail closed is a property of the module
(`detection_modules.fail_closed`), not of the policy — it follows from what the
layer is for, so it is not something a buyer should switch off per account.

- **Fail closed** (TrustedForm, DNC, litigator screening, duplicate detection):
  cap at REVIEW. We will not vouch for something we did not check. Note that
  duplicate detection fails closed for a *commercial* reason rather than a legal
  one — accepting a lead we could not de-duplicate risks charging the buyer
  twice — which is why the column is named for the behaviour rather than for one
  of its several justifications.
- **Fail open** (everything else): score without it, record the coverage gap.
- **Neither ever fails to REJECT.** A vendor outage is not the lead's fault, and
  rejecting on it would destroy good leads the buyer has already paid for.
- An **ACCEPT additionally requires 50% coverage** — we will not vouch for a
  lead we barely checked. A hard stop still rejects regardless.

`SUPER_PIXEL_OUTAGES=trustedform bin/dev` demonstrates this on a running system
without editing code.

### Validated against all twelve seeded leads

`test/engine/seed_lead_verdicts_test.rb` runs every lead end to end through the
real evaluators and aggregator. `expected_verdict` is used **only there**, as a
test oracle: it is stored as `expected_verdict_hint` and a test asserts by grep
that nothing under `app/` reads that column.

Cross-referencing `leads.json` against `accounts.json` turns up something the
brief does not mention — **three of the twelve scenarios target a layer the
owning account has not enabled**:

| Lead | Scenario | The gap |
|---|---|---|
| L-1003 | VPN masking | `acct_medicareedge` has no `vpn_proxy` module |
| L-1005 | Litigator + DNC | `acct_autoinsure` has no `blacklist_alliance` |
| L-1009 | Voice-actor fraud | `acct_autoinsure` has no `voice` module |

So the suite runs **two passes**:

- **Full stack** — every module enabled. All 12 derive their hinted verdict. This
  isolates the scoring model from provisioning.
- **As provisioned** — each account's real modules. 11 of 12 match. **L-1009
  lands REVIEW instead of REJECT**, and I believe that is the correct answer
  rather than a bug: the platform cannot claim voice fraud a buyer never paid to
  detect. A test proves it becomes `REJECT`/`voice_fraud` the moment the module
  is enabled, so the divergence is entirely about provisioning.

The other two still reach the hinted verdict *by a different route*, which is the
consensus idea earning its keep: Anura independently flagged L-1003's
`ANONYMIZER_IP` without being the module bought for that job, and DNC caught
L-1005 with no litigator screening at all.

This is the sharpest available argument for why **not-enabled must never be
modelled as a pass** — AutoInsure would have been sued if DNC hadn't
independently caught the litigator they didn't pay to screen for.

| Lead | Risk | Verdict | Code |
|---|---|---|---|
| L-1001 | 0.00 | ACCEPT | `clean` |
| L-1002 | hard stop | REJECT | `bot_confirmed` |
| L-1003 | 0.25 | REVIEW | `risk_threshold` |
| L-1004 | hard stop | REJECT | `duplicate_hard` |
| L-1005 | hard stop | REJECT | `dnc_listed` (`litigator_confirmed` with a full stack) |
| L-1006 | hard stop | REJECT | `dnc_listed` |
| L-1007 | 0.46 | REVIEW | `risk_threshold` |
| L-1008 | 0.35 | REVIEW | `risk_threshold` |
| L-1009 | 0.41 | REVIEW | `risk_threshold` (REJECT/`voice_fraud` with voice enabled) |
| L-1010 | hard stop | REJECT | `consent_unverifiable` |
| L-1011 | 0.51 | REVIEW | `risk_threshold` |
| L-1012 | 0.15 | ACCEPT | `clean` + soft-duplicate advisory |

### Credit-saving wave execution

Layers run in two waves. **Wave 1** is the cheap dispositive checks (capture 0,
duplicate 1, DNC 1, TrustedForm 1, Anura 2, litigator 2 = **7 credits**);
**wave 2** the expensive weighted signals (VPN 1, email 2, phone 3, enrichment 4,
voice 5 = **15**). An armed hard stop in wave 1 skips wave 2 entirely — the lead
is already dispositively rejected, so those credits would buy information that
cannot change the outcome. Across the seeded data that saves 7–10 credits on each
of the five rejected leads. Switchable off per account
(`accounts.short_circuit_on_hard_stop`) for a buyer who wants the complete
evidence file.

---

## 4. Multi-tenancy

Enforced **in the SQL**, not in the controllers and certainly not in the views.

Every tenant table carries a `NOT NULL account_id`, and every tenant model
applies a default scope built from request-local `Current.account`:

```ruby
Lead.find(other_accounts_lead_id)   # => ActiveRecord::RecordNotFound
```

There is no controller bug, crafted parameter or forgotten `where` that produces
a cross-tenant read, because the predicate is not optional. `test/models/
tenant_isolation_test.rb` attacks the database directly — finds, `find_by!`,
`count`, `update_all`, association traversal, and the generated SQL — so none of
it passes merely because a view rendered nothing.

Three deliberate choices:

1. **Missing tenant context raises** rather than defaulting to `all`. A screen
   that forgets to establish an account fails loudly in development and 500s in
   production; the alternative default would silently leak every tenant's data
   the first time someone forgot.
2. **`super_admin` gets no blanket bypass.** They have `account_id = NULL`, so
   the scope raises for *them* too — signing in as the operator and visiting
   `/leads` returns 404, not everything. Cross-account reads happen only inside
   `TenantScope.across_accounts`, opened only from `Platform::` controllers.
3. **Creation is scoped too.** `Lead.create!` inside a tenant scope gets that
   `account_id` from the scope, so a new row cannot be misattributed by omission.

**On `default_scope`.** I know its reputation. The objection is that it silently
changes queries you did not intend — and a tenant predicate is the one case where
that is the entire point: it genuinely belongs on every query of these tables.
The escape hatch is a single grep-able helper with two callers.

### How super_admin's power is kept from leaking

Four things, not one:

1. No ambient account, so ordinary controllers are unusable for them.
2. The bypass is only reachable from `Platform::BaseController`, which requires
   the role.
3. Every request through it writes an `AdminAccessLog` row naming the account
   read — and that log is a *screen*, because an audit trail nobody can see is a
   compliance decoration.
4. `Permissions` grants an operator only `view_*` verbs. There is no capability
   anywhere that writes tenant data, so there is nothing for a bug to escalate
   into. A test asserts that intersecting an operator's verbs with the writing
   verbs is empty.

---

## 5. Credits

**`credit_ledger_entries` is the source of truth** — append-only, immutable at
the database level, one row per charge carrying the balance it left behind.
`accounts.credits_consumed` is a cached sum of it.

Both exist because affordability must be checked and committed in **one atomic
statement**:

```sql
UPDATE accounts SET credits_consumed = credits_consumed + ?
WHERE id = ? AND monthly_credit_allowance - credits_consumed >= ?
```

Read-then-write would let two concurrent verifications each see a sufficient
balance and both spend it; summing the ledger inside that statement is not
something SQLite will do cheaply. So the counter carries the invariant and the
ledger carries the history — with a reconciliation test proving they never
disagree, including across the seed path, and a rake task to check a running
system. A test races eight threads for 20 credits out of 100 and asserts exactly
five succeed and the balance lands on zero, never below.

**A credit is consumed per layer that actually answered.**
`module_costs_in_credits` is quoted per layer and vendor cost is incurred per
call, so that is the honest unit. Nothing is charged for a layer that was not
enabled, did not apply, errored, or was skipped — enforced by a check
constraint, not just by the charging class. The vendor is called *first* and
charged for *afterwards*: charging first would bill the buyer for our own
outages.

**Retries cannot double-charge.** Each debit carries a unique idempotency key of
`run:<id>:module:<key>`, so a Solid Queue retry hits the unique index instead of
the buyer's balance.

### Out of credits mid-verification

Wave 1 is funded first, because those layers can reject a lead outright and are
therefore worth strictly more per credit than ones that only shade a score.
Whatever remains buys wave-2 layers in ascending cost order, so a thin budget
yields several voices rather than one expensive one. Skipped layers are named in
the verdict's reasons and on the certificate — the verdict may still stand, but
the buyer is told it was not the full check they normally get.

If **even wave 1 is unaffordable, the run halts with no verdict at all.** Not an
accept (that would vouch for a lead we did not finish checking — precisely the
liability this product removes), not a reject (that would destroy a
possibly-good lead over a billing problem). No certificate is issued. The lead
sits in the CRM flagged unverified and re-runnable, and a database check
constraint independently guarantees a halted run can never carry a verdict.

Credits already spent on layers that *did* answer are not refunded — the vendor
calls really were made — and the buyer keeps that evidence.

### Warning early

`credit_health` is `healthy | low | critical | exhausted`, driven by remaining
balance **and days of runway**, because runway is the sharper signal: an account
with 9,000 credits burning 900/day is in more trouble than one with 850 burning
10. Burn rate is measured from the ledger once there are three days of history
and falls back to the modelled rate before that — and the dashboard says *which*,
rather than presenting a modelled figure as a measurement. Without that floor,
extrapolating from seconds of seeded activity reported 64 days of runway for an
account the fixture models at 2.7.

On the seeded data the dashboard flags `acct_autoinsure` (past due, 54 credits,
410/day — under a day) at the top, with `acct_solarpro` behind it at 2.7 days.

---

## 6. Consent certificates

The test applied to every field: holding only this document eighteen months from
now, could a buyer's counsel answer *"on what basis did you call this person?"*

**Contents:** the verdict and its ordered reasons; the policy version that
produced them (so it is reproducible); the retained TrustedForm reference and our
own independent verification of it; first-party capture evidence — dwell time, IP
consistency between visit and submit, field interactions, which is often the most
persuasive part of a TCPA defence and the part no vendor can supply; the raw
vendor response for every layer; an itemised bill.

**And the layers that did *not* run,** each with its reason: not enabled for this
account, not applicable to this lead, unavailable at the time, skipped for
credits, skipped after a hard stop. A certificate listing ten passing layers that
silently omits the one the buyer never subscribed to is a misleading document.
Coverage is stated in words as well as ratios, because "10 of 11" invites the
reader to assume the eleventh failed.

Issued for **rejections too** — a buyer declining a lead needs evidence of why
just as much, whether the argument is with a regulator or with the seller who
invoiced them. Never for a halted run.

### Tamper-evidence, in three layers

1. **SHA-256 over canonical, recursively key-sorted JSON.** Canonicalisation is
   not fussiness: without it, adding a field to the payload builder — or a Ruby
   version changing hash iteration — would invalidate every certificate ever
   issued.
2. **Ed25519 over that digest.** Asymmetric deliberately: with a shared secret we
   would be the only party able to verify, so a buyer defending a lead would be
   asking a regulator to take our word for it. With a published public key
   (`/.well-known/super-pixel-certificate-key`) their counsel verifies
   independently and offline, and we cannot later deny a signature we made.
3. **A per-account hash chain.** A signature proves one document was not edited;
   the chain also proves none were *deleted or reordered* — which is exactly the
   attack the platform operator (us) would be uniquely placed to attempt. A test
   deletes a predecessor and asserts the survivor still has a perfect signature
   but a broken chain.

Plus SQLite triggers making the signed body immutable, with revocation as an
additive field so a revoked certificate stays verifiable as evidence of what was
checked and when.

**Public verification returns integrity status, verdict and which layers ran —
but never PII.** Proving a document is authentic should not require disclosing
its contents to anyone holding a serial number; the owning account sees the full
record after signing in.

---

## 7. Real-time transport

**Server-sent events**, tailing `activity_events` by primary key.

Why, since the brief asks it to be justified:

- The stream is **one-way**. The pixel sends nothing back over it, so a
  bidirectional WebSocket buys nothing and costs a protocol upgrade.
- The consumer is a **third-party page on a buyer's domain**. SSE is cross-origin
  with ordinary CORS headers; ActionCable needs `allowed_request_origins`
  configured per buyer.
- Reconnection is free and **lossless**. The browser resends `Last-Event-ID`
  automatically, and because `activity_events` has a monotonic primary key,
  resuming is `WHERE id > cursor` — no gaps, no duplicates, no replay buffer to
  size. This is the decisive reason.
- The layer jobs run in a **different process** from the web server. With no
  Redis available, ActionCable's async adapter cannot cross that boundary at all,
  so it would need a pubsub dependency purely to reach the browser. Both
  processes already share the database, so tailing a table needs nothing new.

**What this trades away:** a Puma thread per open connection. Correct for a demo
and a modest production load, wrong at tens of thousands of concurrent viewers —
at which point the answer is pubsub behind an evented server, not a bigger thread
pool. The 250ms poll also makes events up to 250ms late, imperceptible beside the
vendor latency it reports on. Database connections are checked out per poll
rather than held for the connection's lifetime, or a handful of open panels would
exhaust the pool.

One append-only table serves the timeline, the audit trail and the live feed,
because they are the same facts viewed differently. The alternative — a timeline
table plus a separate broadcast — is two things that can disagree, and the one a
buyer would rely on in a dispute is the one least likely to be reconciled.

A polling fallback exists for browsers without `EventSource`, using the same
cursor semantics so the two paths cannot disagree about what has been delivered.

---

## 8. Pixel security

`docs/pixel-spec.md` asks three questions.

**"How do you stop someone POSTing leads to another account's pixel?"** The pixel
id is **public** — it sits in the page source — so it cannot be a credential. No
request may nominate its own account: the account is derived server-side from the
pixel record, and a test posts `account_id`, `account` and `lead[account_id]`
simultaneously and asserts the lead lands in the pixel's account regardless. Each
pixel carries an **origin allowlist** set by its owner, and an empty one accepts
nothing rather than everything.

**"What stops the endpoint being abused or replayed?"** `/visit` issues an HMAC
token bound to the session id, the pixel and the visitor's IP, with a 30-minute
TTL. `/leads` refuses a lead without it, so a lead cannot be manufactured without
first loading the page from an allowed origin. It is signed with the **pixel's
own secret**, not a global key, so rotating or revoking a pixel invalidates every
token it ever issued — which is what a buyer would expect "revoke this pixel" to
mean. Comparison is constant-time.

There are **two token purposes**, because `EventSource` cannot set request
headers and so the stream credential must travel in a URL where it may reach
access logs. Rather than put the capture token there, `/leads` issues a separate
**stream token**: five minutes, one lead, read-only. If it leaks, the blast radius
is "somebody watched one lead's verification for five minutes", not "somebody can
inject leads into this account". A test asserts a stream token cannot be used to
submit.

**"What lives client-side vs server-side?"** Everything the client sends is an
*observation*, never an authority. The account comes from the pixel; the submit IP
from the connection; and **form dwell time is recomputed from the server's own
record of when the visit began**, because it is a fraud signal and a fraudster
would send whatever flattered them. A test sends a claimed 90 seconds and asserts
it is not believed.

---

## 9. Jobs

Layer calls run as **Solid Queue background jobs**, one job per layer.

Solid Queue rather than Sidekiq because it is database-backed: durable, with
retries and inspectable state, and no Redis for a grader to install. The
`:async` adapter would have been simpler but loses jobs on restart, and
durability is the point of doing this asynchronously at all.

**One job per layer rather than one per wave**, because vendor calls are
I/O-bound: eleven layers at ~300ms each is 3.3 seconds serially and closer to
600ms in parallel, and for a pixel that has to feel live on a landing page that
difference is the product. The ingestion endpoint enqueues and returns
immediately — the visitor's browser must never wait on eleven vendor calls.

The cost is a coordination problem: when the last layer in a wave finishes,
several jobs may each conclude the wave is over. `WaveCoordinator` solves it with
the status column that already had to exist:

```sql
UPDATE verification_runs SET status = 'wave_2' WHERE id = ? AND status IN (...)
```

One row affected means this job won the election and owns what happens next. No
advisory locks, no extra table, no reliance on queue-level uniqueness — just a
conditional write, the one primitive every database offers. A test fires four
concurrent closers at a settled run and asserts exactly one certificate results.

`Verification::Runner` drives the identical objects with `perform_now` for seeds
and tests, so nothing can pass synchronously and behave differently under a
worker — and a test asserts the async path reaches the same verdict and the same
credit charge as the inline one.

---

## 10. What is stubbed, and what I would do next

### Stubbed, deliberately

- **All ten vendors.** That is what the mock data is for. They sit behind
  `Providers::Gateway`, which also simulates latency (so the live panel genuinely
  streams) and failure (`SUPER_PIXEL_OUTAGES`).
- **Vendor responses for leads the fixtures do not cover** — i.e. anything typed
  into the demo form. `Providers::DerivedSource` stands in for the **vendor
  APIs**, never for the engine: no verdict logic lives in it, and the engine
  cannot tell a derived payload from a fixture one. It resolves in two steps:
  first by looking the contact up in the vendors' own subject index (a real
  vendor recognises a litigator by phone number, not by our internal lead id),
  then by heuristics on observable properties — disposable domains, non-ASCII
  homoglyph domains, automation in the user agent, implausible dwell.
- **TrustedForm certificate creation** for live captures. There is no
  ActiveProspect integration, so a live lead gets a deterministic placeholder
  reference that the layer then verifies against. Inventing a *mismatch* would
  make every demo lead fail the one layer the whole product rests on.
- **Certificate key management.** Generated on first use in development,
  gitignored, `CERTIFICATE_SIGNING_KEY` in production.
- **Email, billing and payment.** Out of scope per the brief.

### Known gaps

- **Certificate key rotation.** `key_id` is recorded per certificate so
  verification looks up the key that signed it rather than assuming the current
  one, but there is no rotation with overlapping validity. That is the first thing
  I would add to make the signing story production-real.
- **Re-verification has no UI beyond a button.** The data model supports it fully
  (that is why `VerificationRun` is separate from `Lead`), and there is a rake
  task, but there is no screen for "re-run everything affected by this policy
  change". I chose not to half-build it.
- **`ActivityEvent` grows without bound.** Fine at this scale; it needs
  partitioning or archival before it isn't.
- **SQLite write contention.** Parallel layer jobs contend on SQLite's single
  writer. `Database::Retry` handles it with backoff and jitter, and every retried
  block is idempotent — but on Postgres, with real MVCC, none of that machinery
  would be necessary. That is the honest cost of choosing a database that needs
  no setup.
- **No rate limiting on the pixel endpoints.** The origin allowlist and capture
  token raise the cost of abuse, but a determined attacker with an allowed origin
  could still flood ingestion and burn a buyer's credits. Per-pixel rate limiting
  is the obvious next control.
- **Phone normalisation is naive** — deliberately predictable NANP handling, which
  is all the fixture data contains. Production wants a real libphonenumber
  binding.
- **`Permissions` is one object, not per-model policies.** Right for three roles
  and a dozen verbs; it would need splitting before the rules start depending on
  individual records.

### With another week, in order

1. **Rate limiting and abuse controls on ingestion**, because it is the only
   externally reachable write path and the only one that spends money.
2. **A review queue as a first-class surface.** Five of twelve seeded leads land
   in REVIEW, which makes "a human looks at this" the single most-used workflow
   in the product — and right now it is a filtered list rather than a queue with
   assignment, disposition and an audit trail of who decided what.
3. **Policy simulation.** Before saving a threshold change, show what it would
   have done to the last 30 days of leads. Tuning an engine blind is how a buyer
   accidentally rejects a week of good traffic; the data to do this properly is
   already stored, since `LayerResult` retains every finding.
4. **Certificate key rotation**, then a PDF rendering of the certificate, because
   that is the artefact a compliance team will actually want to file.

### The biggest risk in the current design

**The weights are asserted, not learned.** Every number in
`ConsensusPolicy::DEFAULT_RULES` is a judgement I can argue for from the domain,
and the twelve seeded leads agree with them — but twelve leads is not evidence,
and I would not claim otherwise. A real deployment needs outcome feedback (which
accepted leads converted, which rejected ones were successfully disputed) to
calibrate them, and until it has that, the honest posture is that the *structure*
is defensible and the *constants* are a starting hypothesis. That is why the
policy is data, why every contribution is recorded per layer, and why the reasons
are stored rather than recomputed: so the calibration is possible later without a
migration.

The second risk is narrower: **noisy-OR assumes the layers are independent**, and
they are not entirely. A datacenter IP and a bot verdict frequently travel
together, so their combined risk is somewhat overstated. Taking the maximum
within a layer handles the worst of it, but genuine cross-layer correlation would
need either a covariance-aware model or explicit grouping — and I would want
outcome data before adding that machinery.

---

## 11. Answers to `docs/DESIGN_QUESTIONS.md`

**1. Core models, and where a verification run lives.** §2. `Account` is the
tenant; `Lead` is what arrived; `VerificationRun` is one evaluation of it under
one policy version; `LayerResult` is one layer's contribution; `ConsentCertificate`
is the signed evidence. The run is a separate entity because re-verification is
real, so the verdict belongs to the run and the lead only points at the latest.

**2. Keeping the three layer states distinct.** Two columns —`state` and
`signal` — with a check constraint making `signal` NULL unless
`state = 'completed'`. A layer nobody paid for cannot masquerade as a pass, and
that is a database guarantee rather than a convention. `skipped_hard_stop` and
`skipped_insufficient_credits` are further distinct states, because "we chose not
to spend your credits" and "you ran out" are different facts.

**3. Hard stops vs weighted signals.** §3. The test: no amount of countervailing
evidence makes the lead purchasable. Eight hard stops, all legal or economic
irreversibility. Everything else is weighted — including Anura `suspect` and
"suspected litigator", both of which the brief flags as judgement calls.

**4. N results → verdict + reason.** Max within a layer, noisy-OR across layers,
compared to two thresholds; any armed hard stop bypasses the score. Every verdict
carries ordered structured reasons, sorted by how much each actually moved the
number, plus advisories and constraints separately.

**5. A layer unavailable mid-run.** Both, chosen per module. Fail-closed layers
cap at REVIEW; the rest fail open with the gap recorded; neither ever rejects,
because a vendor outage is not the lead's fault. An accept additionally needs 50%
coverage. Demonstrable live with `SUPER_PIXEL_OUTAGES`.

**6. How a buyer tunes it; is policy data or code?** Both, split on purpose. The
*vocabulary* of hard stops is code, because each encodes a claim that must be
reviewable in a diff. *Which are armed*, all weights and all thresholds are data,
editable at `/policy`. "Treat suspected litigator as a hard stop" is one boolean.
Disarming a hard stop leaves a 0.65 weight rather than nothing.

**7. Guaranteeing no cross-account reads, at the query layer.** §4. `NOT NULL
account_id` everywhere plus a default scope from `Current.account`, so
`Lead.find(id)` raises `RecordNotFound` for another account's row. Missing context
raises rather than returning everything. Tested by attacking the database
directly — finds, counts, `update_all`, associations and generated SQL.

**8. How super_admin differs, and containing it.** §4. No ambient account (so
ordinary controllers are unusable for them), a bypass reachable only from
`Platform::` controllers, an audit row per cross-account read that is shown as a
screen, and `view_*`-only capabilities so there is nothing to escalate into.

**9. When a credit is consumed.** Per layer that actually answered, because
`module_costs_in_credits` is quoted per layer and vendor cost is per call. Never
for not-enabled, not-applicable, errored or skipped layers — enforced by a check
constraint. Charged after the vendor answers, never before.

**10. Zero credits mid-verification; what the dashboard shows; how early it
warns.** §5. Wave 1 funded first; if even that is unaffordable the run halts with
**no verdict and no certificate**, because neither accepting nor rejecting is
honest. The dashboard sorts by urgency, leads with a "needs attention" block, and
shows balance, burn rate, days of runway and whether that rate is measured or
modelled. Warnings start at 20% remaining or three days of runway — and a
`credits_low` activity event fires per run, so it reaches the timeline as well as
the screen.

**11. What goes in a certificate; tamper-evidence.** §6. Verdict, reasons, policy
version, retained TrustedForm reference plus our verification of it, first-party
capture evidence, every layer's raw response, an itemised bill, and every layer
that did *not* run with its reason. Canonical JSON → SHA-256 → Ed25519, plus a
per-account hash chain that also detects deletion and reordering, plus storage
triggers.

**12. Sync or background jobs, and why.** Background, one job per layer. §9.
Vendor calls are I/O-bound, so parallel execution is ~5× faster wall-clock, and
the visitor's browser must not wait on them. The cost is a wave-coordination
election, solved with a conditional status update.

**13. Real-time transport and what was traded away.** SSE. §7. Chosen mainly for
lossless `Last-Event-ID` resumption off a monotonic primary key, and because the
job worker and web server share only a database. Traded away: a thread per
connection, and up to 250ms of latency.

**14. First thing next, and the biggest risk.** §10. Next: rate limiting on
ingestion, then a real review queue, then policy simulation. Biggest risk: the
weights are asserted rather than learned — the structure is defensible, the
constants are a starting hypothesis, and the system is built so they can be
calibrated from outcome data later without a migration.
