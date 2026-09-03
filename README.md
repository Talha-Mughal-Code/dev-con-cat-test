# Super Pixel

> **This repository now contains the completed solution.**
> Start with **[`SOLUTION.md`](SOLUTION.md)** for the architecture, the reasoning
> behind it, and answers to every question in `docs/DESIGN_QUESTIONS.md`.
>
> ```bash
> bundle install
> bin/dev            # prepares, seeds, and starts the app + job worker
> bin/rails test     # 181 tests
> ```
>
> Then open <http://localhost:3000/demo> — the landing page wired to the real
> backend, streaming actual layer-by-layer verdicts.
>
> Sign in as `dana@solarpro.example` (account admin),
> `luis@solarpro.example` (member, read-only), or
> `admin@catchingconsent.example` (platform operator) — password
> `super-pixel-demo-2026` for all of them.
>
> The original brief follows, unchanged.

---

# Super Pixel — Take-Home Assignment

This repository is a **take-home coding assignment** for a mid-to-senior
full-stack Ruby on Rails engineer. It contains the brief, the mock data you'll
build against, and a demoable landing page + pixel snippet. It does **not**
contain a solution — building the Rails app is the assignment.

> Inspired by the "catching consent" super-pixel concept: one pixel that runs a
> lead through many fraud/consent detection layers at once and issues a verdict
> plus a consent certificate.

## Start here
1. Read **[`ASSIGNMENT.md`](ASSIGNMENT.md)** — the full brief and deliverables.
2. Read **[`docs/DESIGN_QUESTIONS.md`](docs/DESIGN_QUESTIONS.md)** — the
   judgement calls we care about, before you write code.
3. Skim **[`docs/provider-modules.md`](docs/provider-modules.md)** and
   **[`docs/data-contracts.md`](docs/data-contracts.md)** to understand the data.
4. Open **[`docs/pixel-spec.md`](docs/pixel-spec.md)** for the pixel + real-time
   requirements.
5. Grading is transparent — see **[`EVALUATION.md`](EVALUATION.md)**.

## Try the live demo right now (no backend needed)
Open `examples/landing-page.html` in a browser, fill in the form, and submit.
The embedded `super-pixel.js` runs in **simulation mode** and streams fake
layer-by-layer results into the live activity panel so you can see the target
experience. Your task is to make that panel reflect **real** results from the
Rails app you build.

```
examples/
├── super-pixel.js     # the embeddable snippet (like a TrustedForm tag)
└── landing-page.html  # a funnel page with a real-time activity panel
```

## What's in this repo
```
ASSIGNMENT.md          # the brief (read first)
EVALUATION.md          # how we grade (open on purpose)
README.md              # this file
docs/                  # provider specs, data contracts, pixel spec, design Qs
mock-data/             # leads, accounts, users, CRM, and 8 provider fixtures
examples/              # pixel snippet + demoable landing page
```

## Timebox
**3–5 business days.** Please don't exceed it. Depth over breadth — a crisp core
with a clear `SOLUTION.md` beats a sprawling half-built system.

## What we're really looking for
How **you** think. Use AI tools if you like, but the follow-up interview digs
into your architecture, and the parts that matter — the data model, the
consensus engine, multi-tenant isolation, credit accounting, and a genuinely
real-time pixel — are the parts you have to drive yourself. Show us your
reasoning.

## Submitting
Push to a Git repo (this zip is structured to become one — see below) and share
the link, or send a zip of your finished app. Include your `SOLUTION.md`.

### Turning this into a GitHub repo
```bash
cd catching-consent-assignment
git init
git add .
git commit -m "Assignment starter kit"
git branch -M main
git remote add origin git@github.com:YOUR-ORG/super-pixel-assignment.git
git push -u origin main
```
