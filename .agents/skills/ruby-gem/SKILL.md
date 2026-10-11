---
name: ruby-gem
description: Design, implement, and verify idiomatic Ruby gem APIs, DSLs, executables, and packaging.
---

# Ruby gem workflow

Read  .agents/AGENTS.md and the relevant Ruby implementation. Keep Ruby >=3.2 support. Use ordinary classes/modules, keyword arguments for named options, and explicit errors. Preserve the require path and executable contract.

Before changing an exported symbol, inspect its references and examples. Prefer one clear convention to parallel APIs. Do not add Rails or metaprogramming merely to shorten code. Freeze owned constants, not caller-owned objects. Validate portability at persistence boundaries and preserve Ruby input semantics before serialization.

Exercise the actual public API and CLI with temporary PostgreSQL. Run focused behavior tests and bundle exec rake test. For packaging changes, build the gem, inspect its manifest, install it into an isolated GEM_HOME, and execute outside the checkout. Packaging success alone does not prove agent execution.

Report files/symbols changed, concrete consumer behavior, observed verification, and missing prerequisites. Never claim a live provider call without observing one.

Integration tests always: exercise the real PostgreSQL-backed consumer flow for behavioral changes. Unit checks alone are insufficient.
