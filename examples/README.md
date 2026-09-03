# examples/

## What changed, and why

This directory originally held `super-pixel.js` (running in **simulation mode**)
and `landing-page.html` consuming its faked events.

The simulation is **gone**. `EVALUATION.md` lists "the real-time page is still
the bundled simulation" as a red flag, and rightly: a pixel that invents
reassuring verdicts when the backend is unreachable is worse than one that
plainly reports it is offline.

The real pixel now lives at **[`public/super-pixel.js`](../public/super-pixel.js)**,
served by the Rails app at `/super-pixel.js`. There is one copy, so nothing can
drift.

## Two ways to see it work

### 1. Same-origin (simplest)

```bash
bin/dev          # starts Puma and the Solid Queue worker
open http://localhost:3000/demo
```

`/demo` renders this same funnel from `app/views/demo/show.html.erb`, with a
`data-pixel-id` belonging to a real seeded account and a `data-endpoint`
pointing at this deployment.

### 2. Genuinely cross-origin (the more interesting one)

The pixel's real job is running on **someone else's domain**, so it is worth
seeing that path exercised - CORS, the origin allowlist and the capture token
all doing their work:

```bash
bin/dev                                   # terminal 1: the app on :3000
python3 -m http.server 3001 -d examples   # terminal 2: this directory on :3001
open http://localhost:3001/landing-page.html
```

`http://localhost:3001` is in every seeded pixel's allowlist, so the requests
are accepted and the panel fills in from the real backend.

### Why `file://` does not work

Opening `landing-page.html` straight off disk sends `Origin: null`, which is not
on any pixel's allowlist, so the ingestion endpoint refuses it — and the panel
will say so.

That is the control working, not a bug. The pixel id is public (it sits in the
page source), so it cannot be a credential; the origin allowlist is what stops a
third party posting leads into someone else's account. Serve the page over HTTP
as above.
