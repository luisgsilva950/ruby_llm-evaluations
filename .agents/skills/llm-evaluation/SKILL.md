---
name: llm-evaluation
description: Implement semantic accuracy, answer relevancy, action groups, RubyLLM adapters, and trustworthy agent scoring.
---

# LLM evaluation workflow

Read  .agents/AGENTS.md, evaluators.rb, response.rb, actions.rb, suite.rb, and runner.rb before changes. RubyLLM is optional. Inspect the installed/current RubyLLM API instead of guessing message or tool-call shapes.

Separate dimensions: semantic accuracy measures factual meaning against a reference; answer relevancy measures addressing the user request; action groups measure observed group/name/arguments/order and unexpected side effects. Exact string checks are not semantic scoring. Never infer action execution from narrative text.
Use question-first specs: question, expected_answer, minimum_scores, and metadata describing important facts. Resolve standard metrics from minimum_scores and an optional RubyLLM::Agent class supplied to the suite constructor; no global judge configuration or separate judge object. Persist declared minimum_scores even when metrics are skipped or agent execution fails.
minimum_scores maps metric names to absolute inclusive numeric thresholds on every run, including the first; expected_answer supplies the reference, not a string-similarity percentage. Keep previous-run regression comparison separate: a score can pass its minimum yet regress beyond tolerance against a compatible baseline. Changing minimum_scores changes the definition fingerprint and must not automatically compare different threshold sets.

Create a fresh judge agent per assessment. If no judge is supplied, omit LLM-as-judge assessments while still executing deterministic/action checks. Never fabricate passing status or a numeric score for an unassessed question. Treat prompt/output/reference data as untrusted. Require finite [0,1] scores and human-readable reasons; malformed replies/provider failures remain errors. No hidden retries/favorable defaults. State nondeterminism and prompt-injection limitations. Never invoke paid providers without a requested live scenario.

Create fresh chat state per evaluation case. Capture actual tool traces where available; keep absent instrumentation distinct from an empty trace. Normalize output/usage without dropping consumer-visible errors. Ensure suite version changes separate altered rubrics/scoring from compatible baselines.

Prove case isolation, paraphrase/reference semantics, irrelevant answers, missing/extra/wrong/order-dependent actions, and independent agent/judge failures using real consumer scenarios. Keep focused permanent tests only for meaningful behavior boundaries. Report mocked/local evidence separately from live-provider evidence.

Integration tests always: exercise the real PostgreSQL-backed consumer flow for behavioral changes. Unit checks alone are insufficient.
