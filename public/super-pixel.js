/*
 * Super Pixel - the embeddable snippet.
 * ---------------------------------------------------------------------------
 * One tag a lead buyer drops on their landing page, exactly like a TrustedForm
 * header snippet:
 *
 *   <script async src="https://your-app.example/super-pixel.js"
 *           data-pixel-id="px_9f2a01"
 *           data-endpoint="https://your-app.example/api/pixel"></script>
 *
 * THE SIMULATION IS GONE. The reference implementation shipped with the
 * assignment faked layer-by-layer results client-side so the page was demoable
 * with no backend. Every event this file emits now comes from the Rails app:
 * real vendor responses, run through the real consensus engine, streamed back
 * as each background job completes. There is deliberately no fallback - a pixel
 * that invents reassuring verdicts when the backend is unreachable would be
 * worse than one that plainly reports it is offline.
 *
 * WHAT IT DOES
 *   1. On page load, POSTs /visit and records page context. The response carries
 *      a short-lived capture token and the layer list this account actually pays
 *      for, so the panel shows the real stack rather than a hardcoded one.
 *   2. Instruments the lead form - focus, blur, change - as first-party evidence
 *      of how the form was filled. Those events render locally with no network
 *      round trip; there is no reason to make a visitor's keystrokes wait on a
 *      server to be drawn on their own screen.
 *   3. On submit, POSTs the lead and subscribes to its verification stream.
 *   4. Surfaces each layer's result as it lands, then the final verdict.
 *
 * WHAT IS TRUSTED. Nothing here. Everything this file sends is client-supplied
 * and treated as an observation, not an authority: the account comes from the
 * pixel record server-side, the submit IP from the connection, and the dwell
 * time is recomputed from the server's own record of when the visit began -
 * because a bot would simply report a flattering number.
 */
(function () {
  "use strict";

  var script =
    document.currentScript ||
    (function () {
      var tags = document.getElementsByTagName("script");
      return tags[tags.length - 1];
    })();

  var CONFIG = {
    pixelId: script && script.getAttribute("data-pixel-id"),
    endpoint: (script && script.getAttribute("data-endpoint") || "").replace(/\/$/, ""),
    debug: script && script.getAttribute("data-debug") === "true"
  };

  if (!CONFIG.pixelId || !CONFIG.endpoint) {
    warn("data-pixel-id and data-endpoint are both required; the pixel is inert.");
    return;
  }

  // --- a tiny event bus, so the host page can render activity ---------------
  //
  // The bus keeps a HISTORY as well as a listener list, because the tag is
  // loaded async and therefore races the host page's inline script. Whichever
  // wins, the page must end up with every event - including the ones emitted
  // before it subscribed. Without the history, a page that lost the race
  // silently rendered nothing at all, forever, which is exactly the failure
  // this pixel exists not to have.
  var listeners = [];
  var history = [];
  // A run emits on the order of fifteen events; the cap is only there so a
  // long-lived single-page app cannot grow this without bound.
  var HISTORY_LIMIT = 200;

  function emit(event) {
    if (CONFIG.debug) log(event);
    history.push(event);
    if (history.length > HISTORY_LIMIT) history.shift();

    for (var i = 0; i < listeners.length; i++) {
      deliver(listeners[i], event);
    }
  }

  function deliver(listener, event) {
    try {
      listener(event);
    } catch (e) {
      /* a page's listener must never be able to break capture */
    }
  }

  function log() {
    if (window.console && CONFIG.debug) console.log.apply(console, ["[super-pixel]"].concat([].slice.call(arguments)));
  }

  function warn(message) {
    if (window.console) console.warn("[super-pixel] " + message);
  }

  var SESSION = {
    // Proposed by the client so it can correlate its own events. The server
    // namespaces and hashes it rather than trusting it verbatim.
    session_id: "s_" + Date.now().toString(36) + "_" + Math.random().toString(36).slice(2, 10),
    pixel_id: CONFIG.pixelId,
    page_url: location.href,
    referrer: document.referrer || null,
    started_at: new Date().toISOString(),
    interactions: [],
    token: null,
    layers: []
  };

  function request(path, body) {
    return fetch(CONFIG.endpoint + path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      // So a submit-and-navigate does not lose the lead.
      keepalive: true,
      // The pixel runs on a buyer's domain, not ours, so this is a genuine
      // cross-origin call. No credentials are sent: authorisation is the
      // capture token, not a cookie.
      mode: "cors",
      credentials: "omit"
    }).then(function (response) {
      return response
        .json()
        .catch(function () { return {}; })
        .then(function (payload) {
          if (!response.ok) {
            var error = new Error(payload.error || "HTTP " + response.status);
            error.status = response.status;
            throw error;
          }
          return payload;
        });
    });
  }

  // --- 1. the site-visit beacon --------------------------------------------
  // Fired before the visitor types anything, which is the point: it records the
  // IP they are BROWSING from so the backend can later compare it against the
  // IP they SUBMIT from. Without a beacon at page load there is only one IP to
  // look at, and the whole "browsed on a real IP, submitted through a VPN"
  // class of fraud is invisible.
  function openSession() {
    return request("/visit", {
      session_id: SESSION.session_id,
      pixel_id: SESSION.pixel_id,
      page_url: SESSION.page_url,
      referrer: SESSION.referrer,
      started_at: SESSION.started_at
    })
      .then(function (payload) {
        SESSION.session_id = payload.session_id || SESSION.session_id;
        SESSION.token = payload.token;
        SESSION.layers = payload.layers || [];
        emit({ type: "session_started", session: SESSION, layers: SESSION.layers });
        return payload;
      })
      .catch(function (error) {
        // Reported, never papered over. A page that silently pretends to be
        // protected is the failure mode this product exists to remove.
        warn("could not open a capture session: " + error.message);
        emit({ type: "error", message: "Capture session could not be opened: " + error.message });
        throw error;
      });
  }

  var sessionReady = openSession();

  // --- 2. form instrumentation ---------------------------------------------
  function trackForm(form) {
    if (form.__superPixelAttached) return;
    form.__superPixelAttached = true;

    var fields = form.querySelectorAll("input, select, textarea");

    Array.prototype.forEach.call(fields, function (element) {
      ["focus", "blur", "change"].forEach(function (type) {
        element.addEventListener(type, function () {
          var interaction = {
            name: element.name || element.id || "(unnamed)",
            action: type,
            at: new Date().toISOString()
          };
          SESSION.interactions.push(interaction);
          // Rendered from the local bus: there is no reason to make a visitor's
          // own keystrokes wait on a server round trip to appear on their screen.
          emit({ type: "field", interaction: interaction });
        });
      });
    });

    form.addEventListener("submit", function (event) {
      // The demo funnel stays on the page so the panel can be watched. A real
      // integration lets the form submit normally and captures in parallel.
      if (form.hasAttribute("data-pixel-demo")) event.preventDefault();

      var values = {};
      Array.prototype.forEach.call(fields, function (element) {
        if (!element.name) return;
        if (element.type === "checkbox") {
          values[element.name] = element.checked;
        } else if (element.type === "radio") {
          if (element.checked) values[element.name] = element.value;
        } else {
          values[element.name] = element.value;
        }
      });

      emit({ type: "submitted", fields: values });
      submitLead(values);
    });
  }

  // --- 3. submit -----------------------------------------------------------
  function submitLead(values) {
    sessionReady
      .then(function () {
        return request("/leads", {
          session_id: SESSION.session_id,
          pixel_id: SESSION.pixel_id,
          token: SESSION.token,
          submitted_at: new Date().toISOString(),
          // Sent as an observation. The server recomputes it from its own record
          // of when the visit began, because this is a fraud signal and a
          // fraudster would report whatever flattered them.
          form_dwell_ms: Date.now() - new Date(SESSION.started_at).getTime(),
          page_url: SESSION.page_url,
          fields: values,
          interactions: SESSION.interactions
        });
      })
      .then(function (payload) {
        emit({ type: "accepted", lead_id: payload.lead_id });
        subscribe(payload);
      })
      .catch(function (error) {
        warn("lead was not accepted: " + error.message);
        emit({ type: "error", message: "Lead was not accepted: " + error.message });
      });
  }

  // --- 4. the live verification stream -------------------------------------
  // Server-sent events. One-way, cross-origin over ordinary CORS, and - the
  // part that matters - losslessly resumable: the browser resends Last-Event-ID
  // on reconnect and the server replays from that cursor, so a dropped
  // connection mid-verification loses nothing and duplicates nothing.
  function subscribe(payload) {
    if (!window.EventSource) {
      warn("this browser has no EventSource; falling back to polling");
      return poll(payload);
    }

    var source = new EventSource(streamUrl(payload));

    source.addEventListener("layer_result", function (event) {
      emit(withType("layer_result", event));
    });

    source.addEventListener("final_verdict", function (event) {
      emit(withType("final_verdict", event));
      // The verdict is terminal, so hold the connection open no longer.
      source.close();
    });

    source.addEventListener("info", function (event) {
      emit(withType("info", event));
    });

    source.onerror = function () {
      // EventSource reconnects on its own, and the cursor makes that safe, so
      // this is informational rather than fatal.
      log("stream interrupted; the browser will reconnect");
    };

    return source;
  }

  // activity_url already carries the pixel id, so the token is appended rather
  // than assumed to be the first parameter.
  function streamUrl(payload) {
    var origin = CONFIG.endpoint.replace(/\/api\/pixel$/, "");
    var separator = payload.activity_url.indexOf("?") === -1 ? "?" : "&";
    return origin + payload.activity_url + separator +
      "token=" + encodeURIComponent(payload.stream_token);
  }

  function withType(type, event) {
    var data = {};
    try {
      data = JSON.parse(event.data);
    } catch (e) {
      /* ignore a malformed frame rather than break the stream */
    }
    data.type = type;
    return data;
  }

  // Only for browsers without EventSource. Same cursor semantics, so the two
  // paths cannot disagree about what has already been seen.
  function poll(payload) {
    var cursor = 0;
    var attempts = 0;

    (function tick() {
      if (attempts++ > 120) return;

      fetch(streamUrl(payload) + "&cursor=" + cursor + "&format=json", {
        mode: "cors",
        credentials: "omit"
      })
        .then(function (response) { return response.json(); })
        .then(function (events) {
          (events || []).forEach(function (item) {
            cursor = item.id;
            emit(item);
          });
          var done = (events || []).some(function (item) { return item.type === "final_verdict"; });
          if (!done) setTimeout(tick, 700);
        })
        .catch(function () { setTimeout(tick, 1500); });
    })();
  }

  // --- public API -----------------------------------------------------------
  var SuperPixel = {
    config: CONFIG,
    session: SESSION,
    // Replays everything already emitted, so subscribing late costs nothing.
    onActivity: function (callback) {
      listeners.push(callback);
      for (var i = 0; i < history.length; i++) {
        deliver(callback, history[i]);
      }
    },
    attach: trackForm
  };

  window.SuperPixel = SuperPixel;

  // The ready queue, which is how an async tag is meant to be consumed: the
  // host page pushes a callback whether or not this script has run yet.
  //
  //   (window.SuperPixelQueue = window.SuperPixelQueue || []).push(function (pixel) {
  //     pixel.onActivity(render);
  //   });
  //
  // Anything queued before we loaded is drained now; anything pushed afterwards
  // runs immediately. So `if (window.SuperPixel)` - which is only true if the
  // page happened to win the race - is never the right test, and never needed.
  var queued = window.SuperPixelQueue || [];
  window.SuperPixelQueue = {
    push: function (callback) {
      deliver(callback, SuperPixel);
      return 1;
    }
  };
  for (var q = 0; q < queued.length; q++) {
    deliver(queued[q], SuperPixel);
  }

  function boot() {
    Array.prototype.forEach.call(document.querySelectorAll("form[data-pixel-form]"), trackForm);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
