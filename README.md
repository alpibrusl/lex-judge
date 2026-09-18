# lex-judge

Typed judgments from a System One model, as a `[net]`-only Lex effect.

```lex
import "lex-judge/judge" as judge

fn triage(key :: Str, ticket :: Str) -> [net] Result[Str, Str] {
  match judge.ask(judge.make(key), ticket, [
    ("team", JudgeChoice("Which team should handle this?", [
      ("billing",   "Payment, charges and refunds"),
      ("technical", "Bugs or outages"),
      ("sales",     "Pricing and plans")
    ]))
  ]) {
    Err(m) => Err(m),
    Ok(answers) => {
      let a := judge.lookup(answers, "team")
      if judge.decided(a, 0.8) {
        Ok(judge.chosen(a))
      } else {
        Ok("human-review")
      }
    },
  }
}
```

## Why

An AI step in a Lex program has always cost more than the call. Reaching a
provider library drags `llm` into the effect row, usually `io` for config, and
a parse that can fail at runtime — so "this function asks a model something"
becomes a signature nobody can read and a failure mode nobody catches.

[TypeSafe](https://typesafe.ai)'s System One models return **typed judgments
with calibrated probabilities** rather than text: no prose, no code, no
reasoning trace. That makes them expressible as an ordinary HTTP call returning
an ordinary value, which is what this package is:

- the row is **`[net]` and nothing else**
- `--allow-net-host api.typesafe.ai` pins where it can go
- a caller's own row widens by exactly `net`

## The three question types

| constructor | asks | answer carries |
|---|---|---|
| `JudgeNoul(instructions)` | a yes/no | probability the statement is true |
| `JudgeChoice(instructions, options)` | pick one of a closed set | chosen key, probability per option, confidence |
| `JudgeScore(instructions, levels)` | rate against ordered levels | score (may land between levels), probability per level, confidence |

Ask them in one batch. The vendor documents batching as roughly an order of
magnitude cheaper and faster than one call per question, and a batch also keeps
every judgment about a piece of state on the same snapshot of it.

## Confidence is a second axis

For Choice and Score the answer carries both a distribution and a `confidence`
summarising how peaked it is. Keeping them separate is the point: **the answer
tells you what, confidence tells you whether to act.**

`decided(answer, min_confidence)` is the only policy this package expresses,
and it is a helper you may ignore — nothing here refuses anything. A Noul has
no separate confidence, so its distance from `0.5` is its certainty, and `0.5`
exactly means the model is saying it does not know. That is information, not a
failure.

## Code owns the workflow

`ask` returns answers; the caller thresholds them. Keep rules, arithmetic and
exact lookups in code and spend the model only where semantic understanding is
actually required — which is the vendor's own advice and worth following.

## What the tests pin

A judgment API's failure mode is not a crash. It is a decoder that quietly
returns an empty distribution or a zero probability, which downstream code
reads as a *confident* answer. So most of the suite is about the decoder:

- **Both documented shapes for `probabilities`.** The API reference documents an
  object keyed by option; the primitives page documents an array. Reading the
  wire settles it — the service sends an **object** — but both are accepted,
  because a decoder that picks one and is wrong returns an empty distribution
  rather than an error.
- **An integral probability is not read as zero.** A probability of exactly `1`
  can arrive as a JSON integer; reading only floats would decode certainty as
  `0.0` and invert the answer.
- **An unknown answer type is `JudgeMissing`, not coerced** into one we know.
- **Answers are matched to their question ids**, not to their order.
- **The credential is redacted where wire data enters.** An endpoint that echoes
  the `Authorization` header back would otherwise get its caller to write the
  key into whatever the caller logs.

## Running

```bash
lex run --allow-effects env,io,net --allow-net-host api.typesafe.ai \
  examples/live_check.lex go        # needs TYPESAFE_API_KEY
lex ci
```

The key arrives from the environment, never as a CLI argument: an argument is
visible to every other process through the process list.

## This repository

`main` is the package as written — multiple files, tests, this README.

`vcs-mirror` is a **derived** branch: the [lex-vcs](https://vcs.lexlang.org)
op-log rendered as a git history, one commit per typed AST operation, with each
change's *intent prompt* as the commit message. It is force-updated from the
op-log and is not append-only; treat it as a readable backup of the op-log, not
as history you can build on.

The op-log is the source of truth for `src/judge.lex`. Everything else —
tests, examples, this README — lives in git, because lex-vcs versions `.lex`
source inside a package and nothing else.
