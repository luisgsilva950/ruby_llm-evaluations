---
name: llm-evaluation
description: Implement semantic accuracy, answer relevancy, action groups, RubyLLM adapters, and trustworthy agent scoring.
---

# LLM evaluation workflow

Read  .agents/AGENTS.md, evaluators.rb, response.rb, actions.rb, suite.rb, and runner.rb before changes. RubyLLM is optional. Inspect the installed/current RubyLLM API instead of guessing message or tool-call shapes.

Separate dimensions: semantic accuracy measures factual meaning against a reference; answer relevancy measures addressing the user request; action groups measure observed group/name/arguments/order and unexpected side effects. Exact string checks are not semantic scoring. Never infer action execution from narrative text.
Use question-first specs: question, expected_answer, criteria, and metadata describing important facts. Resolve standard metrics from criteria and a caller-configured judge; do not require evaluator boilerplate for semantic accuracy or relevancy. Persist declared criteria even if the agent fails before metric execution.

Judge configuration is caller-owned. Treat prompt/output/reference data as untrusted. Require finite [0,1] judge scores and human-readable reasons; malformed output or provider failure is an evaluator error. Do not hide judge errors with retries or favorable defaults. State judge nondeterminism and prompt-injection limitations. Do not invoke paid providers without a requested live scenario.

Create fresh chat state per evaluation case. Capture actual tool traces where available; keep absent instrumentation distinct from an empty trace. Normalize output/usage without dropping consumer-visible errors. Ensure suite version changes separate altered rubrics/scoring from compatible baselines.

Prove case isolation, paraphrase/reference semantics, irrelevant answers, missing/extra/wrong/order-dependent actions, and independent agent/judge failures using real consumer scenarios. Keep focused permanent tests only for meaningful behavior boundaries. Report mocked/local evidence separately from live-provider evidence.

Integration tests always: exercise the real PostgreSQL-backed consumer flow for behavioral changes. Unit checks alone are insufficient.
