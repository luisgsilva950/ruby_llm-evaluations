---
name: ruby-gem
description: Design, implement, and verify idiomatic Ruby gem APIs, DSLs, executables, and packaging.
---

# Ruby gem workflow

Read  .agents/AGENTS.md and the relevant Ruby implementation. Keep Ruby >=3.2 support. Use ordinary classes/modules, keyword arguments for named options, and explicit errors. Preserve the require path and executable contract.

Before changing an exported symbol, inspect its references and examples. Prefer one clear convention to parallel APIs. Do not add Rails or metaprogramming merely to shorten code. Freeze owned constants, not caller-owned objects. Validate portability at persistence boundaries and preserve Ruby input semantics before serialization. Let ActiveRecord select PostgreSQL, SQLite, or MySQL; consumers add their chosen driver, and no database driver is a mandatory gem dependency. Rails uses its normal host pool and migrations; the standalone CLI defaults to sqlite3:ruby_llm_evaluations.sqlite3.

The final verifier exercises the actual public API and CLI with isolated temporary SQLite, PostgreSQL, and MySQL storage, runs focused behavior tests, the integration suite, and bundle exec rake test. Preserve immutable UUID evidence and chronological baseline ordering on every adapter. For packaging changes, build the gem, inspect its manifest, install it into an isolated GEM_HOME, and execute outside the checkout with the chosen driver supplied by the consumer. Packaging success alone does not prove agent execution.

Report files/symbols changed, concrete consumer behavior, observed verification, and missing prerequisites. Never claim a live provider call without observing one.

Integration tests always: exercise real SQLite-, PostgreSQL-, and MySQL-backed consumer flows for behavioral changes; never silently skip an unavailable database. Unit checks alone are insufficient.
