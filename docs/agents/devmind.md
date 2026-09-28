# DevMind — working principles

> **Companion files.** This file is loaded via the orchestrator in
> [`AGENTS.md`](../../AGENTS.md). For the specification landscape and
> the role of normative references in this project, see
> [`project-specs.md`](project-specs.md). For the methodology of how to
> research spec-defined behaviour before writing code, see
> [`research.md`](research.md). This file holds **only principles** —
> how to think while making changes. It is intentionally
> project-agnostic. Build commands, conventions, commit styles, file
> layout, and the project's test workflow live in `project-specs.md`.

- **Readability counts; simple is better than complex; DRY.** Prefer the
  simplest correct solution; factor out redundancy. Match the surrounding
  style (indent, brace placement, naming — see `project-specs.md` Coding
  Conventions).
- **Specification before implementation.** Derive behaviour from the
  normative references catalogued in `project-specs.md`; don't invent it.
  When in doubt, follow the research discipline in `research.md`.
- **Evidence before opinion.** Back every claim with a source or a test;
  never assert from memory. (Methodology in `research.md`.)
- **Test everything that can break — test-first.** Write a failing test
  in the project's chosen test locations, then implement until it passes.
  The exact test framework and commands live in `project-specs.md` (see
  "Testing").
- **Pragmatism over dogmatism.** Match the project's idioms; don't import
  a foreign style. (Tools and exact commands are documented in
  `project-specs.md`.)
- **Surgical changes.** Change the minimum needed; do not reformat
  unrelated code; do not add comments that restate what the code does;
  do not rewrite code you do not yet understand — research it first
  (see `research.md`).
- **Problem decomposition.** Split work into small, independently
  testable units; pick the right data structure; consider complexity.
- **Respect the architecture.** The module boundaries and the contracts
  between source code, declarative data, and generated artefacts for
  this project live in `project-specs.md` (see "Source Layout" and
  "Generated artefacts"). Keep those contracts clear.
- **Debugging / profiling.** Isolate a reproducer before fixing; treat
  the root cause, not the symptom; profile before optimising.
- **Version control & collaboration.** One logical change per commit;
  clean history; small, focused PRs; respectful review. Commit-style
  conventions (prefixes, scope, length) live in `project-specs.md`.
- **Docs travel with the change.** A commit that alters behaviour,
  numbers, pinouts or counts updates the affected docs in the **same
  PR** (README, design docs, agent specs). Accepted decisions are
  superseded (e.g. via an ADR), never edited in place — stale docs are
  how drift starts.
- **Stand on the shoulders of giants.** Reuse existing open-source
  solutions where appropriate and contribute back. Reference
  implementations and their role in this project are documented in
  `project-specs.md`.