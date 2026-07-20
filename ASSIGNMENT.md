# Take-Home Assignment: The "Super Pixel" Consent & Fraud Platform

**Role:** Mid-to-Senior Full-Stack Engineer (Ruby on Rails)
**Time budget:** 3–5 business days. Please do **not** exceed this. We would rather
see a smaller, well-reasoned system than a sprawling unfinished one.
**Stack:** Ruby on Rails (any recent version). Front-end is your choice
(Hotwire/Turbo, ERB, React, etc.). Any DB. Background jobs of your choice.

---

## 1. Why this assignment exists

We are hiring someone who can look at a messy, real-world problem and **design a
system**, not someone who can only prompt an AI into scaffolding a CRUD app. The
domain below is deliberately underspecified in places. We want to see the
decisions **you** make and, more importantly, *why*.

You may use AI tools — we won't pretend otherwise — but the interview that
follows this assignment will dig hard into your architecture. If you can't
defend a choice in your own words, it will show. The parts that matter
(the data model, the consensus logic, the multi-tenancy and credit accounting,
the real-time pixel) are exactly the parts AI is worst at getting right without a
human driving. Spend your thinking there.

**Read [`docs/DESIGN_QUESTIONS.md`](docs/DESIGN_QUESTIONS.md) before you write
code.** It's a list of the judgement calls we care about.

---

## 2. The problem, in plain terms

Companies buy leads (a person who filled out a form wanting, say, a solar quote
or a Medicare plan). Lead buyers get burned constantly: bots, VPN-masked
fraudsters, people who never actually consented to be called, serial TCPA
litigators fishing for lawsuits, numbers on the Do-Not-Call registry, dead
emails, voice-actor fraud, and the same lead sold to them twice.

Today a buyer would have to integrate a dozen different vendors to catch all of
this. The product you're building is a **single pixel** — one snippet a buyer
drops on their landing page, exactly like a TrustedForm snippet — that sits in
front of every lead and runs it through **many detection layers at once**, then
issues a verdict and a **consent certificate**.

The guiding metaphor is **consensus**: *one provider is an opinion; several
providers agreeing is a signal.* No single layer decides. Your engine gathers
every layer's voice and produces one defensible verdict.

### The detection layers (the "voices")

Full descriptions and the exact data shapes are in
[`docs/provider-modules.md`](docs/provider-modules.md). In short:

| Layer | Question it answers |
|---|---|
| **VPN & Proxy Detection** | Is the visitor hiding behind a VPN/proxy/Tor? Does the site-visit IP match the submit IP? |
| **Anura.io** | Is this a bot, malware, or a human fraud farm vs. real human traffic? |
| **TrustedForm** | Does a retained consent certificate exist, and does it actually match this lead's claim? |
| **Blacklist Alliance** | Is this a known serial TCPA litigator / professional plaintiff? |
| **DNC.com** | Is the number on a Do-Not-Call list? Is the callback window open? |
| **Phone validation (consensus)** | Do multiple phone providers agree the number is real and reachable? |
| **Email validation (consensus)** | Do multiple email providers agree the address is deliverable? |
| **Data enrichment (AudienceLabs / ByteMine)** | Do two enrichment sources agree on the identity/address, and does it match the lead? |
| **Duplicate detection** | Is this lead **already** in this buyer's CRM (so they'd pay twice)? |
| **Voice AI** *(in-development)* | For voice leads: is this a reused voice actor or a synthetic voice? |

We give you **mock data** for every one of these (see `mock-data/`). You do
**not** call real vendors. You read the mock verdicts and build the machinery
around them.

---

## 3. What you are building

A multi-tenant Rails application with roughly these surfaces. How you slice them
into models, services, and jobs is **your** design.

### 3.1 Authentication & multi-tenancy
- A login screen and session handling.
- **Accounts** (tenant buyers) contain **users**. A user only ever sees their
  own account's data. See `mock-data/accounts.json` and `users.json`.
- Roles: `super_admin` (platform operator, sees everything), `account_admin`,
  and `member`. Enforce authorization, don't just hide buttons.

### 3.2 Pixel management
- An account admin can create a **pixel**, scoped to their account, and get a
  copy-paste snippet (like the one in `examples/super-pixel.js`).
- Pixels have an id, a name, the landing page(s) they're allowed on, and which
  detection layers/modules are enabled for that account.

### 3.3 Lead ingestion + the Super Pixel
- An HTTP endpoint the pixel POSTs leads to (see the snippet's `/visit` and
  `/leads` calls for the contract you need to accept — or define your own and
  document it).
- When a lead arrives, run it through the **enabled detection layers** (reading
  the mock provider data), record each layer's result, and compute a
  **consensus verdict** (e.g. `ACCEPT` / `REVIEW` / `REJECT`, plus the reason).
  Doing the layer calls as **background jobs** is strongly encouraged — explain
  your choice either way.

### 3.4 The consensus engine
This is the heart of the assignment. Given all the layers' voices for a lead,
produce a verdict **and an explanation**. Think about: hard stops (litigator,
DNC) vs. soft signals (one email provider disagreeing), weighting, thresholds,
what "REVIEW" means, and what happens when a layer is unavailable or an account
hasn't paid for it. There is no single correct scheme — show us yours and
justify it.

### 3.5 Consent certificates
- For each processed lead, **issue a consent certificate** capturing what was
  checked, the verdict, the retained TrustedForm reference, a timestamp, and
  enough evidence that the buyer could defend the lead later. Certificates
  should be retrievable/verifiable. Decide their format and immutability story.

### 3.6 CRM & activity
- Leads land in a per-account **CRM** view: searchable/filterable, showing each
  lead's verdict, the per-layer breakdown, and its certificate.
- An **activity** timeline: what the pixel and the engine did, when. This is
  also what powers the real-time landing-page panel (below).

### 3.7 Real-time landing page demo
- Ship a working **landing page with the pixel embedded** (start from
  `examples/landing-page.html`) where, **as the form is filled and submitted,
  the detection activity displays in real time** — proving the pixel works.
- The example page runs in a local simulation with no backend. Your job is to
  **wire it to your Rails app** so the live panel reflects *real* verification
  results streaming back (SSE, WebSocket, ActionCable, or polling — your call,
  justify it).

### 3.8 Super-admin overview
- A platform-level dashboard (super_admin only) across **all** accounts:
  which accounts exist, their subscription/plan, **credit balance and burn
  rate**, and who's about to run dry. See `accounts.json` — one account is
  nearly out of credits and past due. Decide what your system does when an
  account hits zero mid-verification.

---

## 4. Scope & guardrails (please read)

- **Timebox to 3–5 business days.** Cut breadth before depth. A crisp core with
  a clear README beats ten half-features.
- It's completely fine to **stub or fake** things at the edges (e.g. real vendor
  APIs — that's what the mock data is for; email delivery; payment). Say what you
  stubbed and why.
- We are **not** grading pixel-perfect UI. Clean and legible is plenty.
- **Do not build** real vendor integrations, real billing/Stripe, or a native
  mobile app. Out of scope.
- If you run short on time, **prioritise**: auth + multi-tenancy → ingestion →
  consensus engine → certificates → real-time landing page → super-admin. Note
  in your README what you'd do next.

---

## 5. Deliverables

1. The Rails app in this repo (or a repo generated from this zip).
2. A top-level **`SOLUTION.md`** covering:
   - How to run it (setup, seed, start, the demo landing page URL).
   - Your **data model** (a diagram or clear description).
   - Your **consensus engine** design and the reasoning behind it.
   - Your **multi-tenancy + credit accounting** approach.
   - Your **real-time transport** choice and why.
   - What you stubbed, what you'd do with another week, and known gaps.
   - Short answers to the questions in `docs/DESIGN_QUESTIONS.md`.
3. Seed data loaded from the provided `mock-data/` files.
4. Tests for the parts that matter most (you choose — but the consensus engine
   and the authorization boundaries are the obvious candidates).

---

## 6. How we'll evaluate

The full rubric is in [`EVALUATION.md`](EVALUATION.md) — it's open on purpose,
read it. Headline: we care most about **domain modeling, the consensus engine,
correct multi-tenant isolation, credit accounting, and a real (not faked)
real-time pixel**, plus the clarity of your reasoning in `SOLUTION.md`.

Good luck — we're genuinely interested in how you think.
