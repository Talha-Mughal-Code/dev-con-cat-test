# Mock Data Contracts

Everything under `mock-data/` is fixture data for you to seed from. It is
internally consistent: the same `lead_id` and `account_id` values appear across
files so you can join them.

Every JSON file has a leading `_comment` (and some records have `_note`)
explaining intent. Strip these before importing, or keep them — your call.

```
mock-data/
├── leads.json                     # 12 inbound leads (L-1001 … L-1012)
├── accounts.json                  # 3 tenant accounts + plans, credits, module costs
├── users.json                     # users per account + roles (incl. one super_admin)
├── buyers_crm.json                # existing CRM records per account (for dup detection)
└── providers/
    ├── vpn_proxy.json             # VPN/proxy/Tor + site-visit-vs-submit IP match
    ├── anura.json                 # good | suspect | bad
    ├── trustedform.json           # verified | mismatch | expired | not_found
    ├── blacklist_alliance.json    # clean | suspected | litigator
    ├── dnc.json                   # callable | dnc_listed | internal_dnc
    ├── phone_validation.json      # 3 providers per lead
    ├── email_validation.json      # 2 providers per lead
    ├── enrichment.json            # audiencelabs + bytemine
    └── voice.json                 # human_unique | human_reused_actor | synthetic | null
```

## Key identifiers
- `lead_id` — e.g. `L-1001`. Primary join key across all provider files.
- `account_id` — e.g. `acct_solarpro`. Ties leads, users, CRM records, credits.
- `pixel_id` — e.g. `px_9f2a01`. Which pixel captured the lead.

## The 12 leads at a glance
Each lead has an `expected_verdict` field. **It is a hint for you while you
build — do not hardcode against it.** Your engine should *derive* the verdict
from the provider signals; the hint just tells you which scenario each lead
exercises so you can sanity-check your logic.

| Lead | Scenario it tests | Hint |
|---|---|---|
| L-1001 | Clean, everything agrees | ACCEPT |
| L-1002 | Bot: datacenter IP, python-requests, disposable email, sub-second fill | REJECT |
| L-1003 | VPN mask: visit IP ≠ submit IP, commercial VPN | REVIEW |
| L-1004 | **Exact duplicate** already in acct_medicareedge CRM | REJECT_DUPLICATE |
| L-1005 | Confirmed serial **litigator** + DNC listed | REJECT |
| L-1006 | DNC listed but otherwise clean (has a voice sample) | REJECT |
| L-1007 | Phone providers **disagree**; low device reputation | REVIEW |
| L-1008 | Email undeliverable (homoglyph domain), both providers agree | REVIEW |
| L-1009 | **Voice-actor fraud** + proxy pool + fraud-farm cluster | REJECT |
| L-1010 | TrustedForm **mismatch/expired** — consent can't be proven | REJECT |
| L-1011 | Enrichment sources **disagree**; suspected (not confirmed) litigator | REVIEW |
| L-1012 | Clean, high value, but a **soft duplicate** (same phone, diff email) | ACCEPT |

These hints are not a grading key — reasonable engines may land a borderline
lead on REVIEW vs REJECT differently. We care about the *reasoning*, which your
per-layer breakdown and `SOLUTION.md` should make visible.

## Credits
`accounts.json` includes `module_costs_in_credits` (per-layer cost) and, per
account, the plan, allowance, used, remaining, and burn rate. `acct_autoinsure`
is intentionally near-zero and `past_due` — exercise your super-admin dashboard
and your "out of credits" behaviour against it.
