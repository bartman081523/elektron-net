# AGENTS.md

This file is the **orchestrator / metaprompt** for AI coding agents working
in this repository. It is intentionally project-agnostic — it only routes
work to the three companion files. Every project-specific fact (specs,
tools, build, conventions, architecture, testing, CI, runtime) lives in
[`docs/agents/project-specs.md`](docs/agents/project-specs.md).

## Companion files

- **[`docs/agents/project-specs.md`](docs/agents/project-specs.md)** — the
  single source of truth for everything project-specific: specs, tools,
  build, conventions, architecture, testing, CI, runtime, dependencies.
  **Load this for almost every coding task.**
- **[`docs/agents/research.md`](docs/agents/research.md)** — methodology for
  investigating spec-defined behaviour before writing code
  (evidence-first, cite-the-spec, flag-unknowns, controlled vocabularies).
  **Load when investigating or implementing spec-defined behaviour.**
- **[`docs/agents/devmind.md`](docs/agents/devmind.md)** — a
  language-agnostic engineering mindset (readability, test-first, surgical
  changes, respect-architecture). **Load as a default working stance.**

The four files cross-link at the top of each one and form a single
guidance bundle; treat them as one document with this file as the router.

## When to load which

| Task                                          | project-specs.md | research.md     | devmind.md |
|-----------------------------------------------|:-----------------:|:---------------:|:----------:|
| Implement / modify code, configuration, tests | ✓                 | if spec-defined | ✓          |
| Investigate spec-defined behaviour            | ✓                 | ✓               | ✓          |
| Refactor / cleanup / PR review                | ✓                 | —               | ✓          |
| Just read / explore                           | ✓                 | —               | —          |
| Pure build / CI / dependency question         | ✓                 | —               | —          |

## Ground truth

When the repo and your memory disagree, trust the repo
([`research.md`](docs/agents/research.md)).