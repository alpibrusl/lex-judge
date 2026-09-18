# lex-judge must be importable ALONGSIDE lex-schema/json_value.
#
# Lex shares one constructor namespace across every imported module. While this
# package used the builtin `std.json` `Json`, any consumer that also imported
# json_value — which is most of this ecosystem — had two types named `Json`
# with identical `JStr`/`JObj`/`JFloat` constructors in scope, and every
# constructor failed to resolve. A type error rather than a silent
# mis-inference, which is the safe failure, but it made the package unusable
# exactly where it was wanted: lex-code needed its own inline copy of this
# decoder rather than importing it.
#
# This file is the regression test, and it tests by EXISTING: it imports both,
# builds a json_value value, and hands it to lex-judge. If the two types ever
# diverge again, this stops compiling — which is the check.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "lex-schema/json_value" as jv

import "../src/judge" as judge

# Built with json_value's constructors, decoded by lex-judge. One `Json`.
fn a_json_value_value_reaches_lex_judge() -> Result[Unit, Str] {
  let answer := JObj([("type", JStr("noul")), ("noul", JFloat(0.77))])
  let a := judge.answer_of("q", answer)
  if judge.noul_p(a) >= 0.76 and judge.noul_p(a) <= 0.78 {
    Ok(())
  } else {
    Err("a json_value value should decode through lex-judge unchanged")
  }
}

# And the other direction: what lex-judge builds is json_value's type, so
# json_value's own functions can read it.
fn lex_judge_returns_a_json_value_value() -> Result[Unit, Str] {
  let q := judge.question_json(JudgeNoul("is it so?"))
  match jv.get_field(q, "type") {
    Some(JStr(t)) => if t == "noul" {
      Ok(())
    } else {
      Err(str.concat("type: ", t))
    },
    _ => Err("json_value should be able to read what lex-judge built"),
  }
}

type Case = { name :: Str, result :: Result[Unit, Str] }

fn c(name :: Str, result :: Result[Unit, Str]) -> Case {
  { name: name, result: result }
}

fn run_all() -> [io] Unit {
  let results := [c("a_json_value_value_reaches_lex_judge", a_json_value_value_reaches_lex_judge()), c("lex_judge_returns_a_json_value_value", lex_judge_returns_a_json_value_value())]
  let failures := list.fold(results, 0, fn (n :: Int, k :: Case) -> [io] Int {
    match k.result {
      Ok(_) => n,
      Err(e) => {
        let __p := io.print(str.join(["FAIL  ", k.name, ": ", e], ""))
        n + 1
      },
    }
  })
  let __s := io.print(str.join(["coexistence: ", jv.stringify(JInt(list.len(results) - failures)), "/", jv.stringify(JInt(list.len(results))), " passed"], ""))
  if failures == 0 {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

