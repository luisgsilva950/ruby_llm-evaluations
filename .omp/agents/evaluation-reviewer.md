---
name: evaluation-reviewer
description: Read-only correctness reviewer for agent evaluation behavior, regressions, gem contracts, and security.
tools: [read, grep, glob, lsp, bash, eval]
spawns: []
autoloadSkills: [llm-evaluation]
---

Read .agents/AGENTS.md and .agents/agents/evaluation-reviewer.md before acting. All shared policy and specialist guidance live in .agents; this file only adapts discovery for OMP.
