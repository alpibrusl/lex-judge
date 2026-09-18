import "std.bytes" as bytes

import "std.http" as http

import "std.json" as json

import "std.list" as list

import "std.map" as map

import "std.str" as str

fn noul_p(a :: Answer) -> Float {
  match a {
    JudgeNoulAnswer(p) => p,
    _ => 0.5,
  }
}

fn make(api_key :: Str) -> Judge {
  { api_key: api_key, base_url: "https://api.typesafe.ai", model: "jev-latest", timeout_ms: 30000 }
}

fn redact(j :: Judge, s :: Str) -> Str {
  match str.is_empty(j.api_key) {
    true => s,
    false => str.replace(s, j.api_key, "[redacted]"),
  }
}

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

fn lookup(answers :: List[(Str, Answer)], id :: Str) -> Answer {
  list.fold(answers, JudgeMissing(id), fn (acc :: Answer, a :: (Str, Answer)) -> Answer {
    match acc {
      JudgeMissing(_) => match a {
        (k, v) => match (k == id) {
          true => v,
          false => acc,
        },
      },
      _ => acc,
    }
  })
}

fn str_at(j :: Json, name :: Str) -> Str {
  match field(j, name) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn num_at(j :: Json, name :: Str) -> Float {
  match field(j, name) {
    None => 0.0,
    Some(v) => num(v),
  }
}

fn prob_pairs(j :: Json) -> List[(Str, Float)] {
  match j {
    JObj(kvs) => list.map(kvs, fn (kv :: (Str, Json)) -> (Str, Float) {
      match kv {
        (k, v) => (k, num(v)),
      }
    }),
    JList(xs) => list.map(list.enumerate(xs), fn (p :: (Int, Json)) -> (Str, Float) {
      match p {
        (i, v) => (int_str(i), num(v)),
      }
    }),
    _ => [],
  }
}

type Judge = { api_key :: Str, base_url :: Str, model :: Str, timeout_ms :: Int }

fn int_as_float(i :: Int) -> Float {
  match json.decode(str.concat(int_str(i), ".0")) {
    Ok(JFloat(f)) => f,
    _ => 0.0,
  }
}

fn int_str(i :: Int) -> Str {
  json.encode(JInt(i))
}

fn num(j :: Json) -> Float {
  match j {
    JFloat(f) => f,
    JInt(i) => int_as_float(i),
    _ => 0.0,
  }
}

fn prob_values(j :: Json) -> List[Float] {
  list.map(prob_pairs(j), fn (p :: (Str, Float)) -> Float {
    match p {
      (_, v) => v,
    }
  })
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

type Answer = JudgeChoiceAnswer((Str, List[(Str, Float)], Float)) | JudgeMissing(Str) | JudgeNoulAnswer(Float) | JudgeScoreAnswer((Float, List[Float], Float))

fn request_json(j :: Judge, state :: Str, questions :: List[(Str, Question)]) -> Json {
  JObj([("state", JStr(state)), ("model", JStr(j.model)), ("questions", JObj(list.map(questions, fn (q :: (Str, Question)) -> (Str, Json) {
    match q {
      (id, question) => (id, question_json(question)),
    }
  })))])
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

fn question_json(q :: Question) -> Json {
  match q {
    JudgeNoul(instructions) => JObj([("type", JStr("noul")), ("instructions", JStr(instructions))]),
    JudgeChoice(instructions, options) => JObj([("type", JStr("choice")), ("instructions", JStr(instructions)), ("criteria", JObj(list.map(options, fn (o :: (Str, Str)) -> (Str, Json) {
      match o {
        (k, description) => (k, JStr(description)),
      }
    })))]),
    JudgeScore(instructions, levels) => JObj([("type", JStr("score")), ("instructions", JStr(instructions)), ("criteria", JList(list.map(levels, fn (l :: Str) -> Json {
      JStr(l)
    })))]),
  }
}

fn score_of(a :: Answer) -> Float {
  match a {
    JudgeScoreAnswer(s, _, _) => s,
    _ => 0.0,
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
