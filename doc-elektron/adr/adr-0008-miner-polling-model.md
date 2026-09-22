# ADR-0008: Work-update model of `mining/miner.py`

**Status:** Proposed — open design question (architecture scan, question
I5). No decision made yet; see options below.

## Context

The reference CPU miner's main loop
(`mining/miner.py:470-494`) works like this:

1. Fetch a fresh `getblocktemplate` (`:473-476`).
2. Run `mine_block(...)` until it finds a nonce — the hash round has no
   deadline and no abort on new block arrival (`:486`).
3. On RPC error, sleep 5 s and retry (`:479`); in continuous mode, sleep
   1 s after each round (`:494`) before fetching the next template.

With the fork's 60 s block spacing, this model wastes work in two
distinct ways:

- **Between rounds:** work is fetched on a fixed interval, so a new
  block's template is only noticed after the current round finishes.
- **Within a round:** if a new block arrives mid-round, the miner keeps
  hashing against a superseded tip for the remainder of the round; the
  eventual submission would be rejected.

The server side already offers the standard remedy: the fork's
`getblocktemplate` supports the BIP 22 long-poll mechanism — a
`longpollid` response field, a `longpollid` request parameter that delays
the response until the template would change, and `'longpoll'` as a
declared client capability (`src/rpc/mining.cpp:647`, `:654`, `:701`,
`:745`). The Python miner does not use it (no longpoll reference exists
in `mining/miner.py`).

## Options

1. **Long-poll for template updates (recommended).** Keep the
   `longpollid` of the current template and issue the next
   `getblocktemplate` call with it; the server blocks until work changes.
   Minimal RPC traffic and prompt updates, no polling interval to tune.
2. **Cheap tip polling during hashing.** Query the best block hash on a
   short interval inside `mine_block` and abort the round when it
   changes. Simple, but adds RPC load and needs an interval trade-off.
3. **Bounded hash rounds.** Cap each `mine_block` round (e.g. a few
   seconds of work) and re-fetch between rounds. No server dependency,
   but bounds efficiency at low hashrates and still reacts only between
   rounds.

## Consequences

- Options are composable: long-poll (1) fixes the between-round staleness;
  an in-flight round still needs a deadline, so (2) or a bounded round
  remains useful even with (1).
- Without any of these, the miner's effective stale-work rate scales
  with block arrival frequency — tolerable on a 60 s chain for solo
  testing, but it silently discards work on every block boundary.
- Any change here is mining-side only (no consensus or node change);
  `mining/` is built and versioned independently of the node.

See the design issue tracking this ADR for the maintainer question.

**Upstream design issue:** [kutlusoy/elektron-net#61](https://github.com/kutlusoy/elektron-net/issues/61)