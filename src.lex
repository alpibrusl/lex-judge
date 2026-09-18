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

fn int_as_float(i :: Int) -> Float {
  match json.decode(str.concat(int_str(i), ".0")) {
    Ok(JFloat(f)) => f,
    _ => 0.0,
  }
}

fn int_str(i :: Int) -> Str {
  json.encode(JInt(i))
}

fn ask(j :: Judge, state :: Str, questions :: List[(Str, Question)]) -> [net] Result[List[(Str, Answer)], Str] {
  match list.is_empty(questions) {
    true => Ok([]),
    false => {
      let base := { body: Some(bytes.from_str(json.encode(request_json(j, state, questions)))), headers: map.new(), method: "POST", timeout_ms: Some(j.timeout_ms), url: str.concat(j.base_url, "/v1/systemone") }
      let req := http.with_header(http.with_auth(http.with_timeout_ms(base, j.timeout_ms), "Bearer", j.api_key), "Content-Type", "application/json")
      match http.send(req) {
        Err(_) => Err(str.concat("could not reach ", j.base_url)),
        Ok(r) => match (r.status >= 400) {
          true => Err(str.join(["judgment request returned HTTP ", int_str(r.status), ": ", str.slice(redact(j, body_text(r)), 0, 300)], "")),
          false => match json.decode(redact(j, body_text(r))) {
            Err(m) => Err(str.concat("judgment response was not JSON: ", m)),
            Ok(body) => Ok(answers_of(body, questions)),
          },
        },
      }
    },
  }
}

fn chosen(a :: Answer) -> Str {
  match a {
    JudgeChoiceAnswer(k, _, _) => k,
    _ => "",
  }
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

fn field(j :: Json, name :: Str) -> Option[Json] {
  match j {
    JObj(kvs) => list.fold(kvs, None, fn (acc :: Option[Json], kv :: (Str, Json)) -> Option[Json] {
      match acc {
        Some(v) => Some(v),
        None => match kv {
          (k, v) => match (k == name) {
            true => Some(v),
            false => None,
          },
        },
      }
    }),
    _ => None,
  }
}

fn decided(a :: Answer, min_confidence :: Float) -> Bool {
  match a {
    JudgeNoulAnswer(p) => match (p >= 0.5) {
      true => ((p - 0.5) >= (min_confidence / 2.0)),
      false => ((0.5 - p) >= (min_confidence / 2.0)),
    },
    JudgeChoiceAnswer(_, _, c) => (c >= min_confidence),
    JudgeScoreAnswer(_, _, c) => (c >= min_confidence),
    JudgeMissing(_) => false,
  }
}

fn body_text(r :: HttpResponse) -> Str {
  match bytes.to_str(r.body) {
    Err(_) => "",
    Ok(t) => t,
  }
}
