# Research before implementing

> **Companion files.** This file is loaded via the orchestrator in
> [`AGENTS.md`](../../AGENTS.md). For the specification landscape and
> reference implementations used by this project, see
> [`project-specs.md`](project-specs.md). For the engineering mindset,
> see [`devmind.md`](devmind.md). This file holds **only methodology** —
> how to find out what is correct before writing code. It is intentionally
> project-agnostic.

## Purpose

When implementing code whose behaviour is defined by an external standard
or normative reference (wire formats, file formats, protocol encodings,
type tables, API contracts, algorithm behaviour, spec clauses), correct
behaviour is defined by that reference — not by intuition, not by memory,
not by analogy to other codebases. When you don't yet know something — a
data type, an encoding, a clause — research it before writing code. The
reference landscape itself lives in `project-specs.md`; do not duplicate
it here.

## Sources of truth

1. **This repository** is ground truth for *this project*. Read its
   source, tests, and CI configuration. If the repo and your memory
   disagree, trust the repo.
2. **The normative references and comparison implementations** used by
   this project are catalogued in `project-specs.md` — go there for
   *which* sources matter; come back here for *how* to use them.

## Discipline

- **Evidence-first.** Tie every factual claim to a specific source: a
  `file:line` in this repo, a clause/table in the applicable standard,
  or a function in a comparison implementation. A claim with no source
  is a hypothesis — label it as such.
- **Cite the reference in code.** When implementing spec-defined
  behaviour, cite the clause in a one-line comment, matching the
  project's house style, e.g. `// <STANDARD> <CLAUSE>: …`.
- **Don't invent.** Implement only behaviour backed by the reference
  (see `project-specs.md` for which references apply). Comparison
  implementations are useful for cross-checking but are not
  authoritative — if you can point to no source, leave a `// TODO` and
  ask before implementing. Do not invent data types, encodings, or
  unit suffixes.
- **Controlled vocabularies.** Units, enums, status maps (and analogous
  enumerated vocabularies) are controlled; see `project-specs.md` for
  where the project's vocabulary table lives and how to extend it. Add a
  real entry rather than synthesising strings on the fly.
- **Verify against the repo, not assumptions.** Reproduce a failing case
  before fixing; treat the root cause, not the symptom.
- **Flag the unknowns.** If you cannot verify something, say so and leave
  a `// TODO` rather than guessing.

## Cross-checking against reference implementations

For behaviour defined by a normative reference (formats, type tables,
encodings, compact profiles, date/time handling, etc.), comparison
implementations are useful — see `project-specs.md` for which
implementations this project compares against. The rule of thumb: where
this project and a comparison implementation differ, the normative
reference (not the comparison) decides, unless the project explicitly
declares the comparison authoritative for a defined area.