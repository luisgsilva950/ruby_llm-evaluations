---
name: evaluation-dashboard
description: Build safe accessible read-only evaluation dashboards and inspect the actual browser surface.
---

# Dashboard workflow

Read  .agents/AGENTS.md, dashboard.rb, and relevant templates/assets. Keep the Rack-compatible read-only interface and standalone WEBrick server. GET/HEAD only, loopback by default, local assets, no Rails/Node build system. Treat run metadata, IDs, prompts, answers, action traces, and judge reasons as untrusted content.

Escape content and attributes. Keep JSON attachments valid and prevent path traversal. Ensure invalid requests, missing runs, and unsupported methods produce truthful HTTP status codes. Do not expose write APIs, secrets, or hidden provider requests.

Visualize real persisted runs; separate incompatible suites/datasets rather than implying a continuous comparable trend. Show semantic/relevancy/action scores, per-case expected/actual evidence, and meaningful baseline changes. Support empty history and missing instrumentation without invented data.

Launch the actual dashboard and inspect with a browser. Exercise filters, history/detail navigation, report download, and narrow layouts. Inspect a screenshot, check overflow and accessible names/contrast. HTTP smoke and template checks do not replace visual verification. Close temporary browser/server sessions after proof.

Integration tests always: exercise the real PostgreSQL-backed consumer flow for behavioral changes. Unit checks alone are insufficient.
