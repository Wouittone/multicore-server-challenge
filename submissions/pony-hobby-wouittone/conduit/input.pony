use "collections"
use "json"
use "uri"

primitive Input
  fun integer(value: String): I64 ? =>
    if value.size() == 0 then error end
    for ch in value.values() do
      if (ch < '0') or (ch > '9') then error end
    end
    value.i64()?

  fun required(obj: JSONObject, key: String): String ? =>
    let value = obj(key)? as String
    if (value.size() == 0) or _nul(value) then error end
    value

  fun optional(obj: JSONObject, key: String): (String | None) ? =>
    match obj.get_or_else(key, None)
    | let value: String =>
      if _nul(value) then error end
      value
    | None => None
    else
      error
    end

  fun nonempty(obj: JSONObject, key: String): (String | None) ? =>
    let value = optional(obj, key)?
    match value
    | let s: String => if s.size() == 0 then error end
    end
    value

  fun _nul(value: String): Bool =>
    value.contains(String.from_array(recover val [U8(0)] end))

  fun decode(value: String): String ? =>
    let decoded = PercentDecode(value) as String
    if _nul(decoded) then error end
    decoded

  fun query(raw: String): Map[String, String] val ? =>
    let values = recover iso Map[String, String] end
    let parsed = ParseFormURLEncoded(raw) as FormURLEncoded
    for (key, value) in parsed.pairs() do
      if _nul(key) or _nul(value) then error end
      if not values.contains(key) then values(key) = value end
    end
    consume values
