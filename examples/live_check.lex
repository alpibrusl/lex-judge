# live_check.lex — one real call against the service, all three primitives.
#
# The module's tests are pure and pin the DOCUMENTED contract. This checks the
# documented contract is the one the server actually speaks, which is a
# different question and the only one a live call can answer.
#
# The credential arrives from the environment, never as an argument: a CLI
# argument is visible to every other process on the machine through the process
# list, and a key that leaks that way leaks silently.
#
#   TYPESAFE_API_KEY=... lex run --allow-effects env,io,net \
#     --allow-net-host api.typesafe.ai examples/live_check.lex go

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.float" as float

import "std.io" as io

import "std.env" as env

import "lex-schema/json_value" as jv

import "../src/judge" as judge

fn show(id :: Str, a :: judge.Answer) -> [io] Unit {
  match a {
    JudgeNoulAnswer(p) => io.print(str.join(["  ", id, "  noul   p=", float.to_str(p), "   decided@0.8=", if judge.decided(a, 0.8) {
      "yes"
    } else {
      "no"
    }], "")),
    JudgeChoiceAnswer(k, probs, c) => io.print(str.join(["  ", id, "  choice ", k, "   confidence=", float.to_str(c), "   options=", int.to_str(list.len(probs)), "   decided@0.8=", if judge.decided(a, 0.8) {
      "yes"
    } else {
      "no"
    }], "")),
    JudgeScoreAnswer(s, probs, c) => io.print(str.join(["  ", id, "  score  ", float.to_str(s), "   confidence=", float.to_str(c), "   levels=", int.to_str(list.len(probs))], "")),
    JudgeMissing(m) => io.print(str.join(["  ", id, "  MISSING (", m, ") — the server sent a shape this decoder does not know"], "")),
  }
}

fn go() -> [env, io, net] Unit {
  match env.get("TYPESAFE_API_KEY") {
    None => io.print("set TYPESAFE_API_KEY"),
    Some(key) => {
      let j := judge.make(key)
      let state := "Customer: my payment failed three times and I was still charged twice. I want my money back today."
      let questions := [("refund", JudgeNoul("Does the customer request a refund?")), ("team", JudgeChoice("Which team should handle this?", [("billing", "Payment, charges and refunds"), ("technical", "Bugs or outages"), ("sales", "Pricing and plans")])), ("frustration", JudgeScore("How frustrated does the customer appear?", ["Calm and neutral", "Concerned but civil", "Very angry or strong language"]))]
      match judge.ask(j, state, questions) {
        Err(m) => io.print(str.concat("FAILED: ", m)),
        Ok(answers) => {
          let __h := io.print("live answers:")
          let __r := list.fold(answers, 0, fn (n :: Int, a :: (Str, judge.Answer)) -> [io] Int {
            match a {
              (id, ans) => {
                let __x := show(id, ans)
                n + 1
              },
            }
          })
          io.print("")
        },
      }
    },
  }
}

