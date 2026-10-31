use "json"
use pg = "postgres"

primitive Fields
  fun value(row: pg.Row, index: USize): pg.FieldData ? =>
    row.fields(index)?.value

  fun text(row: pg.Row, index: USize): String ? =>
    value(row, index)? as String

  fun id(row: pg.Row, index: USize = 0): I64 ? =>
    value(row, index)? as I64

  fun boolean(row: pg.Row, index: USize): Bool ? =>
    value(row, index)? as Bool

  fun nullable(row: pg.Row, index: USize): (String | None) ? =>
    match value(row, index)?
    | let s: String => s
    | None => None
    else error
    end

  fun timestamp(row: pg.Row, index: USize): pg.PgTimestamp ? =>
    value(row, index)? as pg.PgTimestamp

  fun strings(row: pg.Row, index: USize): Array[String] val ? =>
    let array = value(row, index)? as pg.PgArray
    let result = recover iso Array[String](array.size()) end
    for element in array.elements.values() do
      result.push(element as String)
    end
    consume result

  fun text_array(values: Array[String] val): pg.PgArray =>
    let elements = recover iso Array[(pg.FieldData | None)] end
    for string in values.values() do elements.push(string) end
    pg.PgArray(25, consume elements)

class val User
  """A user record; the password hash is never part of its JSON representation."""
  let id: I64
  let username: String
  let email: String
  let bio: (String | None)
  let image: (String | None)
  let password_hash: (String | None)

  new val from_row(row: pg.Row, with_password: Bool = false) ? =>
    id = Fields.id(row)?
    username = Fields.text(row, 1)?
    email = Fields.text(row, 2)?
    bio = Fields.nullable(row, 3)?
    image = Fields.nullable(row, 4)?
    password_hash = if with_password then Fields.text(row, 5)? else None end

  fun json(token: String): JSONObject =>
    JSONObject.update("username", username).update("email", email)
      .update("bio", bio).update("image", image).update("token", token)

class val Profile
  """A public profile with following state relative to the current viewer."""
  let username: String
  let bio: (String | None)
  let image: (String | None)
  let following: Bool

  new val from_row(row: pg.Row, start: USize = 0) ? =>
    username = Fields.text(row, start)?
    bio = Fields.nullable(row, start + 1)?
    image = Fields.nullable(row, start + 2)?
    following = Fields.boolean(row, start + 3)?

  new val with_following(profile: Profile, following': Bool) =>
    username = profile.username
    bio = profile.bio
    image = profile.image
    following = following'

  fun json(): JSONObject =>
    JSONObject.update("username", username).update("bio", bio)
      .update("image", image).update("following", following)

class val Article
  """An article projection; list queries do not load the body column."""
  let id: I64
  let slug: String
  let title: String
  let description: String
  let body: (String | None)
  let created_at: pg.PgTimestamp
  let updated_at: pg.PgTimestamp
  let tag_list: Array[String] val
  let favorites_count: I64
  let favorited: Bool
  let author: Profile

  new val from_row(row: pg.Row) ? =>
    id = Fields.id(row)?
    slug = Fields.text(row, 1)?
    title = Fields.text(row, 2)?
    description = Fields.text(row, 3)?
    body = Fields.nullable(row, 4)?
    created_at = Fields.timestamp(row, 5)?
    updated_at = Fields.timestamp(row, 6)?
    tag_list = Fields.strings(row, 7)?
    favorites_count = Fields.id(row, 8)?
    favorited = Fields.boolean(row, 9)?
    author = Profile.from_row(row, 10)?

  fun json(): JSONObject ? =>
    var result = JSONObject.update("slug", slug).update("title", title)
      .update("description", description)
      .update("createdAt", Timestamp(created_at)?)
      .update("updatedAt", Timestamp(updated_at)?)
      .update("tagList", JSONStrings(tag_list))
      .update("favoritesCount", favorites_count)
      .update("favorited", favorited).update("author", author.json())
    match body
    | let text: String => result = result.update("body", text)
    end
    result

class val Comment
  """A comment with its author profile and UTC database timestamps."""
  let id: I64
  let body: String
  let created_at: pg.PgTimestamp
  let updated_at: pg.PgTimestamp
  let author: Profile

  new val from_row(row: pg.Row) ? =>
    id = Fields.id(row)?
    body = Fields.text(row, 1)?
    created_at = Fields.timestamp(row, 2)?
    updated_at = Fields.timestamp(row, 3)?
    author = Profile.from_row(row, 4)?

  fun json(): JSONObject ? =>
    JSONObject.update("id", id).update("body", body)
      .update("createdAt", Timestamp(created_at)?)
      .update("updatedAt", Timestamp(updated_at)?)
      .update("author", author.json())

primitive Timestamp
  """Format a binary UTC PostgreSQL timestamp as millisecond RFC 3339."""
  fun apply(timestamp: pg.PgTimestamp): String ? =>
    let us = timestamp.microseconds
    if (us == I64.max_value()) or (us == I64.min_value()) then error end
    let date: String = timestamp.string()
    // RFC 3339 requires a four-digit year; reject rather than clamp dates.
    if (date.size() < 19) or (date(10)? != ' ') then error end
    let fraction = (((us % 1_000_000) + 1_000_000) % 1_000_000) / 1000
    let milliseconds: String = fraction.string()
    let padding = if milliseconds.size() == 1 then "00"
      elseif milliseconds.size() == 2 then "0"
      else ""
      end
    date.substring(0, 10) + "T" + date.substring(11, 19) + "." +
      padding + milliseconds + "Z"

primitive JSONStrings
  fun apply(strings: Array[String] val): JSONArray =>
    var result = JSONArray
    for string in strings.values() do result = result.push(string) end
    result
