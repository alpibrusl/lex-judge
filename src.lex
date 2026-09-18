import "std.bytes" as bytes

import "std.http" as http

import "std.json" as json

import "std.list" as list

import "std.map" as map

import "std.str" as str

fn answers_of(body :: Json, questions :: List[(Str, Question)]) -> List[(Str, Answer)] {
  let answers := match field(body, "answers") {
    None => JObj([]),
    Some(a) => a,
  }
  list.map(questions, fn (q :: (Str, Question)) -> (Str, Answer) {
    match q {
      (id, _) => (id, match field(answers, id) {
        None => JudgeMissing(id),
        Some(a) => answer_of(id, a),
      }),
    }
  })
}

fn answer_of(id :: Str, j :: Json) -> Answer {
  match str_at(j, "type") {
    "noul" => JudgeNoulAnswer(num_at(j, "noul")),
    "choice" => JudgeChoiceAnswer(str_at(j, "choice"), match field(j, "probabilities") {
      None => [],
      Some(p) => prob_pairs(p),
    }, num_at(j, "confidence")),
    "score" => JudgeScoreAnswer(num_at(j, "score"), match field(j, "probabilities") {
      None => [],
      Some(p) => prob_values(p),
    }, num_at(j, "confidence")),
    _ => JudgeMissing(id),
  }
}
