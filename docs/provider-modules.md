# Detection Layers (the "voices" of the consensus)

Each layer below has a matching mock data file under `mock-data/providers/`.
Every file is keyed by `lead_id`, matching the leads in `mock-data/leads.json`.
You **read** these files (load them into your DB as seed data, or serve them
from a small internal service — your choice). You never call a real vendor.

The single most important idea: **no layer is the answer by itself.** Your
consensus engine combines them. Some are *hard stops*; most are *signals*.

---

## VPN & Proxy Detection — `providers/vpn_proxy.json`
Detects VPN / proxy / Tor / datacenter IPs and whether the **site-visit IP
matches the submit IP** (the "VPN problem": someone browses on their real IP
then submits through a VPN, or vice-versa). Fields: `is_vpn`, `is_proxy`,
`is_tor`, `is_datacenter`, `site_visit_ip_matches_submit_ip`, `risk`.

## Anura.io — `providers/anura.json`
Bot, malware, and human-fraud-farm detection. Separates real humans from
automated submissions, hijacked devices, and fraud-farm labor. `result` is
`good | suspect | bad`, with `rule_ids` explaining why. This is *one* voice in
the consensus, deliberately — a `suspect` shouldn't auto-kill a lead on its own.

## TrustedForm (ActiveProspect) — `providers/trustedform.json`
The consent certificate is **retained and verified**, not just stored. Check
that the cert exists, matches the lead's phone and email, isn't expired, and its
page fingerprint matches the claimed landing page. `status` is
`verified | mismatch | expired | not_found`. A `mismatch`/`expired` is a serious
consent problem.

## Blacklist Alliance — `providers/blacklist_alliance.json`
Screens against known serial TCPA litigators and professional plaintiffs.
`status` is `clean | suspected | litigator`. A confirmed `litigator` is the
textbook **hard stop**. `suspected` is a judgement call — that's the point.

## DNC.com — `providers/dnc.json`
Do-Not-Call registry status + callback-window logic. `dnc_status` is
`callable | dnc_listed | internal_dnc`, plus `callback_window_open`. "If you
can't call it, you shouldn't buy it."

## Phone validation (consensus) — `providers/phone_validation.json`
**Three** independent providers per lead (`twilio_lookup`, `numverify`,
`telesign`). Look for **agreement**, not any single opinion. Watch for VoIP
line types and providers that disagree (e.g. 2 say invalid, 1 says VoIP).

## Email validation (consensus) — `providers/email_validation.json`
**Two** independent providers (`zerobounce`, `neverbounce`). `deliverable`,
`disposable`, `fraud_score`. When both agree undeliverable, that's a strong
signal; a split is a REVIEW candidate.

## Data enrichment — `providers/enrichment.json`
Two sources (`audiencelabs`, `bytemine`) append identity/address/demographics.
Two sources mean **cross-validation**: when they agree with each other and the
lead, coverage is deep; when they disagree, that's a flag. `match_to_lead` tells
you whether the enriched identity matches what the lead submitted.

## Duplicate detection — `mock-data/buyers_crm.json`
Not a vendor — it's the **buyer's own CRM**. Before accepting a lead (and
charging the buyer), check it against existing records **within the same
account**. Match on phone and/or email. Note the difference between a hard
duplicate (same phone AND email) and a soft/possible duplicate (same phone,
different email, recently created) — handle them differently.

## Voice AI (in-development) — `providers/voice.json`
For leads with a voice sample, detects **voice-actor fraud** (same voiceprint
reused across many "different" leads) and synthetic/AI voices. Most leads have
`has_sample: false` — your engine must handle a layer that simply doesn't apply.

---

### A note on "unavailable" vs "pass"
A layer can be: **not enabled** for the account (they didn't pay for it), **not
applicable** to this lead (no voice sample), or **enabled and returned a
verdict**. These are three different states and your engine and certificate
should not conflate them. This distinction is one of the things we're looking
for.
