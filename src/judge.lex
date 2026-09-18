# judge.lex — typed judgments as a [net]-only effect.
#
# A System One model (TypeSafe's Jev) answers one narrow question at a time and
# returns a TYPED answer with calibrated probabilities. It does not write text,
# code, or explanations. That makes it a different thing from an LLM call, and
# the difference is what this module is for: a judgment arrives as a value the
# type system can hold, not as prose someone has to parse.
#
# WHY THIS IS `[net]` AND NOTHING ELSE. The whole cost of an AI step in Lex has
# been its effect row: reaching a provider library drags in `llm`, often `io`
# for config, and a parse that can fail at runtime. This is one HTTP call.
# `--allow-net-host api.typesafe.ai` pins where it can go; the row says what it
# does; and a caller's own row widens by exactly `net` and nothing else.
#
# CODE OWNS THE WORKFLOW. Nothing here decides anything. `ask` returns answers;
# the caller thresholds them. That is deliberate and it is the vendor's own
# advice — keep rules, arithmetic and exact lookups in code, and spend the model
# only where semantic understanding is actually required.
#
# CONFIDENCE IS A SECOND AXIS. For Choice and Score the answer carries both a
# probability distribution and a `confidence` summarising how peaked it is. The
# distinction is worth preserving rather than collapsing: the answer tells you
# WHAT, confidence tells you WHETHER TO ACT. `decided` below is the only policy
# this module expresses, and it is a helper the caller may ignore.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.float" as float

import "std.map" as map

import "std.http" as http

import "std.bytes" as bytes

# `lex-schema/json_value`, NOT `std.json`.
#
# Lex shares ONE constructor namespace across every imported module, and
# json_value defines its own `type Json` with the same `JStr`/`JObj`/`JFloat`
# constructors as the builtin. A package importing this one AND json_value —
# which is most of the ecosystem — would have two types named `Json` in scope
# and every constructor would fail to resolve. It is a type error rather than
# a silent mis-inference, which is the safe failure, but it makes this package
# unusable exactly where it is most wanted: that is not hypothetical, it is why
# lex-code needed its own inline copy of this decoder instead of importing it.
#
# So this follows the ecosystem rather than the newer builtin. `std.json` is
# the better primitive in isolation; compatibility wins here, and nothing in
# this package's PUBLIC surface exposes either — `Question` and `Answer` carry
# `Judge`-prefixed constructors of their own.
import "lex-schema/json_value" as jv

# The endpoint and credential. `base_url` is operator config and must never come
# from anything the model or a caller's data said.
type Judge = { base_url :: Str, api_key :: Str, model :: Str, timeout_ms :: Int }

# The question and answer types, documented together and declared back to back.
#
# They are adjacent on purpose: `lex fmt` deletes a comment that directly
# follows a variant type (lex-lang#755), so a doc block sitting between these
# two declarations would be silently dropped the first time anyone formats the
# file.
#
# Constructors are prefixed because Lex shares ONE constructor namespace across
# every imported module — an unprefixed `Choice` would collide with any other
# package's and mis-infer rather than error.
#
#   Question
#     JudgeNoul         instructions
#     JudgeChoice       instructions, options as (key, description)
#     JudgeScore        instructions, ordered level descriptions
#
#   Answer
#     JudgeNoulAnswer   probability the statement is true; no separate
#                       confidence, because the probability IS the certainty
#     JudgeChoiceAnswer chosen key, probability per key, confidence
#     JudgeScoreAnswer  score (may sit between levels), probability per level,
#                       confidence
#     JudgeMissing      the response carried no answer under that id
type Question = JudgeNoul(Str) | JudgeChoice((Str, List[(Str, Str)])) | JudgeScore((Str, List[Str]))

type Answer = JudgeNoulAnswer(Float) | JudgeChoiceAnswer((Str, List[(Str, Float)], Float)) | JudgeScoreAnswer((Float, List[Float], Float)) | JudgeMissing(Str)

fn make(api_key :: Str) -> Judge {
  { base_url: "https://api.typesafe.ai", api_key: api_key, model: "jev-latest", timeout_ms: 30000 }
}

# ── encoding ─────────────────────────────────────────────────────────────────
fn question_json(q :: Question) -> jv.Json {
  match q {
    JudgeNoul(instructions) => JObj([("type", JStr("noul")), ("instructions", JStr(instructions))]),
    JudgeChoice(instructions, options) => JObj([("type", JStr("choice")), ("instructions", JStr(instructions)), ("criteria", JObj(list.map(options, fn (o :: (Str, Str)) -> (Str, jv.Json) {
      match o {
        (k, description) => (k, JStr(description)),
      }
    })))]),
    JudgeScore(instructions, levels) => JObj([("type", JStr("score")), ("instructions", JStr(instructions)), ("criteria", JList(list.map(levels, fn (l :: Str) -> jv.Json {
      JStr(l)
    })))]),
  }
}

fn request_json(j :: Judge, state :: Str, questions :: List[(Str, Question)]) -> jv.Json {
  JObj([("state", JStr(state)), ("model", JStr(j.model)), ("questions", JObj(list.map(questions, fn (q :: (Str, Question)) -> (Str, jv.Json) {
    match q {
      (id, question) => (id, question_json(question)),
    }
  })))])
}

# ── decoding ────────────────────────────────────────────────────────────────
#
# Everything below leans on json_value's own accessors — `get_field`, `as_str`,
# `as_int`, `as_float`, `as_obj`, `as_list` — rather than matching constructors
# by hand. An earlier version of this file reimplemented all of them, including
# an Int-to-Float conversion that serialised to JSON text and reparsed it when
# `int.to_float` exists. Reimplementing a library's accessors inside a consumer
# of that library is how two decoders drift apart.
# A number from either JSON form. A probability of exactly 1 arrives as an Int,
# so reading only floats would decode certainty as 0.0 and invert the answer.
fn num(j :: jv.Json) -> Float {
  match jv.as_float(j) {
    Some(f) => f,
    None => match jv.as_int(j) {
      Some(i) => int.to_float(i),
      None => 0.0,
    },
  }
}

fn num_at(j :: jv.Json, name :: Str) -> Float {
  match jv.get_field(j, name) {
    None => 0.0,
    Some(v) => num(v),
  }
}

fn str_at(j :: jv.Json, name :: Str) -> Str {
  match jv.get_field(j, name) {
    None => "",
    Some(v) => match jv.as_str(v) {
      Some(t) => t,
      None => "",
    },
  }
}

# `probabilities` is documented as an OBJECT keyed by option in the API
# reference and as an ARRAY in the primitives page. The wire sends an object —
# but both are accepted, because a decoder that picks one and is wrong returns
# an empty distribution rather than failing, and an empty distribution reads
# downstream as a confident zero.
fn prob_pairs(j :: jv.Json) -> List[(Str, Float)] {
  match jv.as_obj(j) {
    Some(kvs) => list.map(kvs, fn (kv :: (Str, jv.Json)) -> (Str, Float) {
      match kv {
        (k, v) => (k, num(v)),
      }
    }),
    None => match jv.as_list(j) {
      Some(xs) => list.map(list.enumerate(xs), fn (p :: (Int, jv.Json)) -> (Str, Float) {
        match p {
          (i, v) => (int.to_str(i), num(v)),
        }
      }),
      None => [],
    },
  }
}

fn prob_values(j :: jv.Json) -> List[Float] {
  list.map(prob_pairs(j), fn (p :: (Str, Float)) -> Float {
    match p {
      (_, v) => v,
    }
  })
}

fn answer_of(id :: Str, j :: jv.Json) -> Answer {
  match str_at(j, "type") {
    "noul" => JudgeNoulAnswer(num_at(j, "noul")),
    "choice" => JudgeChoiceAnswer(str_at(j, "choice"), match jv.get_field(j, "probabilities") {
      None => [],
      Some(p) => prob_pairs(p),
    }, num_at(j, "confidence")),
    "score" => JudgeScoreAnswer(num_at(j, "score"), match jv.get_field(j, "probabilities") {
      None => [],
      Some(p) => prob_values(p),
    }, num_at(j, "confidence")),
    _ => JudgeMissing(id),
  }
}

fn answers_of(body :: jv.Json, questions :: List[(Str, Question)]) -> List[(Str, Answer)] {
  let answers := match jv.get_field(body, "answers") {
    None => JObj([]),
    Some(a) => a,
  }
  list.map(questions, fn (q :: (Str, Question)) -> (Str, Answer) {
    match q {
      (id, _) => (id, match jv.get_field(answers, id) {
        None => JudgeMissing(id),
        Some(a) => answer_of(id, a),
      }),
    }
  })
}

# ── the wire ─────────────────────────────────────────────────────────────────
# Remove the credential from anything that came back off the wire.
#
# This is carried over from a working attack elsewhere, not a hypothesis: an
# endpoint that echoes the Authorization header back gets its caller to write
# the key into whatever the caller logs or records. Redacting HERE means no
# caller can forget to, because nothing downstream ever sees the raw text.
fn redact(j :: Judge, s :: Str) -> Str {
  if str.is_empty(j.api_key) {
    s
  } else {
    str.replace(s, j.api_key, "[redacted]")
  }
}

fn body_text(r :: HttpResponse) -> Str {
  match bytes.to_str(r.body) {
    Err(_) => "",
    Ok(t) => t,
  }
}

# Ask a batch. One call, many questions — the vendor documents batching as an
# order of magnitude cheaper and faster than asking one at a time, and a batch
# also keeps every judgment about one piece of state on the same snapshot of it.
#
# A non-2xx is an error, not an empty answer set: silently treating a 401 as
# "no judgments" is how a system looks healthy while deciding nothing.
fn ask(j :: Judge, state :: Str, questions :: List[(Str, Question)]) -> [net] Result[List[(Str, Answer)], Str] {
  if list.is_empty(questions) {
    Ok([])
  } else {
    let base := { method: "POST", url: str.concat(j.base_url, "/v1/systemone"), headers: map.new(), body: Some(bytes.from_str(jv.stringify(request_json(j, state, questions)))), timeout_ms: Some(j.timeout_ms) }
    let req := http.with_header(http.with_auth(http.with_timeout_ms(base, j.timeout_ms), "Bearer", j.api_key), "Content-Type", "application/json")
    match http.send(req) {
      Err(_) => Err(str.concat("could not reach ", j.base_url)),
      Ok(r) => if r.status >= 400 {
        Err(str.join(["judgment request returned HTTP ", int.to_str(r.status), ": ", str.slice(redact(j, body_text(r)), 0, 300)], ""))
      } else {
        match jv.parse(redact(j, body_text(r))) {
          Err(m) => Err(str.concat("judgment response was not JSON: ", m.message)),
          Ok(body) => Ok(answers_of(body, questions)),
        }
      },
    }
  }
}

# ── reading an answer ────────────────────────────────────────────────────────
fn lookup(answers :: List[(Str, Answer)], id :: Str) -> Answer {
  list.fold(answers, JudgeMissing(id), fn (acc :: Answer, a :: (Str, Answer)) -> Answer {
    match acc {
      JudgeMissing(_) => match a {
        (k, v) => if k == id {
          v
        } else {
          acc
        },
      },
      _ => acc,
    }
  })
}

# Is this answer decided enough to act on without a human?
#
# The ONLY policy this module expresses, and it is a helper rather than a gate:
# nothing here refuses anything. A Noul has no separate confidence, so its
# distance from 0.5 is its certainty — 0.5 exactly means the model is saying it
# does not know, which is information and not a failure.
fn decided(a :: Answer, min_confidence :: Float) -> Bool {
  match a {
    JudgeNoulAnswer(p) => if p >= 0.5 {
      p - 0.5 >= min_confidence / 2.0
    } else {
      0.5 - p >= min_confidence / 2.0
    },
    JudgeChoiceAnswer(_, _, c) => c >= min_confidence,
    JudgeScoreAnswer(_, _, c) => c >= min_confidence,
    JudgeMissing(_) => false,
  }
}

# The probability a Noul is true, or 0.5 (no information) for anything else.
fn noul_p(a :: Answer) -> Float {
  match a {
    JudgeNoulAnswer(p) => p,
    _ => 0.5,
  }
}

# The chosen key, or "" when the answer is not a Choice.
fn chosen(a :: Answer) -> Str {
  match a {
    JudgeChoiceAnswer(k, _, _) => k,
    _ => "",
  }
}

# The score, or 0.0 when the answer is not a Score.
fn score_of(a :: Answer) -> Float {
  match a {
    JudgeScoreAnswer(s, _, _) => s,
    _ => 0.0,
  }
}

