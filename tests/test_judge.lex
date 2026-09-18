# Tests for lex-judge. Everything here is pure: no network, no key.
#
# The wire format is the thing worth pinning. A judgment API's failure mode is
# not a crash — it is a decoder that quietly returns an empty distribution or a
# zero probability, which downstream code reads as a confident answer. So these
# tests are mostly about what the DECODER does with shapes the service actually
# sends, including the two it is documented to send interchangeably.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "lex-schema/json_value" as jv

import "../src/judge" as judge

fn expect(cond :: Bool, msg :: Str) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(msg)
  }
}

fn parse(s :: Str) -> jv.Json {
  match jv.parse(s) {
    Err(_) => JNull,
    Ok(j) => j,
  }
}

fn close(a :: Float, b :: Float) -> Bool {
  if a >= b {
    a - b < 0.0001
  } else {
    b - a < 0.0001
  }
}

# ── request encoding ─────────────────────────────────────────────────────────
#
# Pinned against the documented contract, not against what the encoder happens
# to emit: `type`, `instructions`, and `criteria` as an object for Choice and an
# ARRAY for Score, because Score's levels are ordered and an object would lose
# that order.
fn noul_encodes_to_the_documented_shape() -> Result[Unit, Str] {
  let j := judge.question_json(JudgeNoul("Does the customer request a refund?"))
  let s := jv.stringify(j)
  if not str.contains(s, "\"type\":\"noul\"") {
    Err(str.concat("missing type: ", s))
  } else {
    expect(str.contains(s, "\"instructions\":\"Does the customer request a refund?\""), str.concat("missing instructions: ", s))
  }
}

fn choice_encodes_its_options_as_an_object() -> Result[Unit, Str] {
  let j := judge.question_json(JudgeChoice("Which team?", [("billing", "Payment issues"), ("technical", "Bugs")]))
  let s := jv.stringify(j)
  if not str.contains(s, "\"type\":\"choice\"") {
    Err(str.concat("type: ", s))
  } else {
    expect(str.contains(s, "\"billing\":\"Payment issues\"") and str.contains(s, "\"technical\":\"Bugs\""), str.concat("criteria should be an object keyed by option: ", s))
  }
}

# Score levels are ORDERED — the score can land between them — so they must
# encode as an array. An object would be a silent reordering hazard.
fn score_encodes_its_levels_as_an_ordered_array() -> Result[Unit, Str] {
  let j := judge.question_json(JudgeScore("How frustrated?", ["Calm", "Concerned", "Angry"]))
  let s := jv.stringify(j)
  expect(str.contains(s, "[\"Calm\",\"Concerned\",\"Angry\"]"), str.concat("levels must stay ordered: ", s))
}

fn a_request_carries_state_model_and_questions() -> Result[Unit, Str] {
  let j := judge.request_json(judge.make("k"), "the state", [("q1", JudgeNoul("yes?"))])
  let s := jv.stringify(j)
  if not str.contains(s, "\"model\":\"jev-latest\"") {
    Err(str.concat("model: ", s))
  } else {
    expect(str.contains(s, "\"state\":\"the state\"") and str.contains(s, "\"q1\""), str.concat("state/questions: ", s))
  }
}

# ── answer decoding ──────────────────────────────────────────────────────────
fn a_noul_answer_decodes() -> Result[Unit, Str] {
  let a := judge.answer_of("q", parse("{\"type\":\"noul\",\"noul\":0.92}"))
  expect(close(judge.noul_p(a), 0.92), "noul probability should decode")
}

fn a_choice_answer_decodes_with_its_distribution() -> Result[Unit, Str] {
  let a := judge.answer_of("q", parse("{\"type\":\"choice\",\"choice\":\"billing\",\"probabilities\":{\"billing\":0.85,\"technical\":0.15},\"confidence\":0.82}"))
  match a {
    JudgeChoiceAnswer(k, probs, c) => if k != "billing" {
      Err(str.concat("chosen: ", k))
    } else {
      if list.len(probs) != 2 {
        Err("both options should appear in the distribution")
      } else {
        expect(close(c, 0.82), "confidence should decode")
      }
    },
    _ => Err("should have decoded as a choice"),
  }
}

# The API reference documents `probabilities` as an object keyed by level; the
# primitives page documents an array. Both are accepted, because guessing wrong
# yields an EMPTY distribution — which reads downstream as a confident zero
# rather than as a decode failure.
fn score_probabilities_decode_from_an_object() -> Result[Unit, Str] {
  let a := judge.answer_of("q", parse("{\"type\":\"score\",\"score\":1.6,\"probabilities\":{\"0\":0.05,\"1\":0.3,\"2\":0.65},\"confidence\":0.78}"))
  match a {
    JudgeScoreAnswer(s, probs, _) => if not close(s, 1.6) {
      Err("score should decode")
    } else {
      expect(list.len(probs) == 3, "three levels should decode from an object")
    },
    _ => Err("should have decoded as a score"),
  }
}

fn score_probabilities_decode_from_an_array() -> Result[Unit, Str] {
  let a := judge.answer_of("q", parse("{\"type\":\"score\",\"score\":1.6,\"probabilities\":[0.05,0.3,0.65],\"confidence\":0.78}"))
  match a {
    JudgeScoreAnswer(_, probs, _) => expect(list.len(probs) == 3, "three levels should decode from an array too"),
    _ => Err("should have decoded as a score"),
  }
}

# A probability of exactly 1 arrives as an Int on the wire. Reading only
# JFloat would turn certainty into 0.0 — the single most dangerous rounding
# this decoder could do, because it inverts the answer.
fn an_integral_probability_is_not_read_as_zero() -> Result[Unit, Str] {
  let a := judge.answer_of("q", parse("{\"type\":\"noul\",\"noul\":1}"))
  expect(close(judge.noul_p(a), 1.0), "a probability of exactly 1 must decode as 1.0, not 0.0")
}

fn an_unknown_answer_type_is_missing_not_guessed() -> Result[Unit, Str] {
  let a := judge.answer_of("q7", parse("{\"type\":\"something-new\"}"))
  match a {
    JudgeMissing(id) => expect(id == "q7", "the id should be carried"),
    _ => Err("an unrecognised answer type must not be coerced into one we know"),
  }
}

fn an_absent_answer_is_missing() -> Result[Unit, Str] {
  let answers := judge.answers_of(parse("{\"answers\":{}}"), [("q1", JudgeNoul("yes?"))])
  match judge.lookup(answers, "q1") {
    JudgeMissing(_) => Ok(()),
    _ => Err("a question with no answer must come back Missing"),
  }
}

fn answers_are_matched_to_their_question_ids() -> Result[Unit, Str] {
  let body := parse("{\"answers\":{\"b\":{\"type\":\"noul\",\"noul\":0.9},\"a\":{\"type\":\"noul\",\"noul\":0.1}}}")
  let answers := judge.answers_of(body, [("a", JudgeNoul("?")), ("b", JudgeNoul("?"))])
  if not close(judge.noul_p(judge.lookup(answers, "a")), 0.1) {
    Err("answer `a` was matched to the wrong question")
  } else {
    expect(close(judge.noul_p(judge.lookup(answers, "b")), 0.9), "answer `b` was matched to the wrong question")
  }
}

# ── confidence as a second axis ──────────────────────────────────────────────
fn a_peaked_choice_is_decided() -> Result[Unit, Str] {
  let a := JudgeChoiceAnswer("x", [("x", 0.9)], 0.9)
  expect(judge.decided(a, 0.8), "confidence above the bar should be actionable")
}

fn a_flat_choice_is_not_decided() -> Result[Unit, Str] {
  let a := JudgeChoiceAnswer("x", [("x", 0.34)], 0.2)
  expect(not judge.decided(a, 0.8), "low confidence must not be actionable")
}

# A Noul carries no separate confidence: its distance from 0.5 IS its
# certainty, and 0.5 exactly is the model saying it does not know.
fn a_noul_at_one_half_is_undecided() -> Result[Unit, Str] {
  expect(not judge.decided(JudgeNoulAnswer(0.5), 0.1), "0.5 means no information, in either direction")
}

fn a_confident_no_is_as_decided_as_a_confident_yes() -> Result[Unit, Str] {
  if not judge.decided(JudgeNoulAnswer(0.97), 0.8) {
    Err("a confident yes should be decided")
  } else {
    expect(judge.decided(JudgeNoulAnswer(0.03), 0.8), "a confident NO is equally decided — distance from 0.5, not magnitude")
  }
}

fn a_missing_answer_is_never_decided() -> Result[Unit, Str] {
  expect(not judge.decided(JudgeMissing("q"), 0.0), "a missing answer must not be actionable even at a zero bar")
}

# ── the credential never leaves ──────────────────────────────────────────────
#
# An endpoint that echoes the Authorization header back gets its caller to
# write the key into whatever the caller logs. Redaction happens where wire
# data enters, so no caller can forget it.
fn an_echoed_key_is_redacted() -> Result[Unit, Str] {
  let j := judge.make("sk-secret-value")
  let out := judge.redact(j, "{\"you_sent\":\"Bearer sk-secret-value\"}")
  if str.contains(out, "sk-secret-value") {
    Err("the key survived redaction")
  } else {
    expect(str.contains(out, "[redacted]"), "the redaction should be visible, not silent")
  }
}

fn redaction_leaves_everything_else_alone() -> Result[Unit, Str] {
  let j := judge.make("kkk")
  expect(judge.redact(j, "{\"choice\":\"billing\"}") == "{\"choice\":\"billing\"}", "unrelated text must be untouched")
}

fn an_empty_key_redacts_nothing() -> Result[Unit, Str] {
  expect(judge.redact(judge.make(""), "anything") == "anything", "an empty key must not match everywhere")
}

# ── harness ──────────────────────────────────────────────────────────────────
type Case = { name :: Str, result :: Result[Unit, Str] }

fn c(name :: Str, result :: Result[Unit, Str]) -> Case {
  { name: name, result: result }
}

fn cases() -> List[Case] {
  [c("noul_encodes_to_the_documented_shape", noul_encodes_to_the_documented_shape()), c("choice_encodes_its_options_as_an_object", choice_encodes_its_options_as_an_object()), c("score_encodes_its_levels_as_an_ordered_array", score_encodes_its_levels_as_an_ordered_array()), c("a_request_carries_state_model_and_questions", a_request_carries_state_model_and_questions()), c("a_noul_answer_decodes", a_noul_answer_decodes()), c("a_choice_answer_decodes_with_its_distribution", a_choice_answer_decodes_with_its_distribution()), c("score_probabilities_decode_from_an_object", score_probabilities_decode_from_an_object()), c("score_probabilities_decode_from_an_array", score_probabilities_decode_from_an_array()), c("an_integral_probability_is_not_read_as_zero", an_integral_probability_is_not_read_as_zero()), c("an_unknown_answer_type_is_missing_not_guessed", an_unknown_answer_type_is_missing_not_guessed()), c("an_absent_answer_is_missing", an_absent_answer_is_missing()), c("answers_are_matched_to_their_question_ids", answers_are_matched_to_their_question_ids()), c("a_peaked_choice_is_decided", a_peaked_choice_is_decided()), c("a_flat_choice_is_not_decided", a_flat_choice_is_not_decided()), c("a_noul_at_one_half_is_undecided", a_noul_at_one_half_is_undecided()), c("a_confident_no_is_as_decided_as_a_confident_yes", a_confident_no_is_as_decided_as_a_confident_yes()), c("a_missing_answer_is_never_decided", a_missing_answer_is_never_decided()), c("an_echoed_key_is_redacted", an_echoed_key_is_redacted()), c("redaction_leaves_everything_else_alone", redaction_leaves_everything_else_alone()), c("an_empty_key_redacts_nothing", an_empty_key_redacts_nothing())]
}

fn run_all() -> [io] Unit {
  let results := cases()
  let failures := list.fold(results, 0, fn (n :: Int, k :: Case) -> [io] Int {
    match k.result {
      Ok(_) => n,
      Err(e) => {
        let __p := io.print(str.join(["FAIL  ", k.name, ": ", e], ""))
        n + 1
      },
    }
  })
  let __s := io.print(str.join(["lex-judge: ", jv.stringify(JInt(list.len(results) - failures)), "/", jv.stringify(JInt(list.len(results))), " passed"], ""))
  if failures == 0 {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

