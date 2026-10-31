use "pony_test"
use "json"
use "crypto"
use "encode/base64"
use pg = "postgres"
use "../conduit"

actor Main is TestList
  new create(env: Env) => PonyTest(env, this)
  new make() => None
  fun tag tests(test: PonyTest) =>
    test(_JSON)
    test(_Input)
    test(_Tokens)
    test(_Fields)
    test(_Timestamps)
    test(_Passwords)

class iso _JSON is UnitTest
  fun name(): String => "standard-library-json"
  fun apply(h: TestHelper) ? =>
    let source = """{"user":{"bio":null,"username":"Pony \u2603","n":42}}"""
    let obj = JSONParser.parse(source) as JSONObject
    let user = obj("user")? as JSONObject
    h.assert_true(user("bio")? is None)
    h.assert_eq[I64](42, user("n")? as I64)
    let encoded: String = obj.print()
    let reparsed = JSONParser.parse(encoded) as JSONObject
    h.assert_eq[String](user("username")? as String,
      (reparsed("user")? as JSONObject)("username")? as String)
    let errors = JSONParser.parse(Errors.body("bad")) as JSONObject
    h.assert_eq[String]("bad",
      (((errors("errors")? as JSONObject)("body")? as JSONArray)(0)? as String))

class iso _Input is UnitTest
  fun name(): String => "input-validation"
  fun apply(h: TestHelper) ? =>
    h.assert_eq[I64](100, Input.integer("100")?)
    for invalid in (recover val [""; "-1"; "1.0"; "1e2"; " 1"; "9223372036854775808"] end).values() do
      try Input.integer(invalid)?; h.fail("accepted " + invalid) end
    end
    let params = Input.query("tag=hello+world&offset=2&tag=ignored")?
    h.assert_eq[String]("hello world", params("tag")?)
    h.assert_eq[String]("2", params("offset")?)
    h.assert_eq[String]("a/b", Input.decode("a%2Fb")?)
    try Input.query("tag=%xy")?; h.fail("accepted malformed encoding") end
    h.assert_eq[I64](I64.max_value(), Input.integer("9223372036854775807")?)
    h.assert_eq[I64](5, Input.integer("005")?)
    h.assert_true(Input.nonempty(JSONObject.update("title", None), "title")? is None)
    try Input.nonempty(JSONObject.update("title", ""), "title")?
      h.fail("accepted empty title")
    end
    try Input.required(JSONObject.update("username", I64(42)), "username")?
      h.fail("accepted non-string username")
    end

class iso _Tokens is UnitTest
  fun name(): String => "jwt-hs256"
  fun apply(h: TestHelper) ? =>
    let token = Tokens.issue(123, "secret", 100)?
    h.assert_eq[I64](123, Tokens.verify(token, "secret", 101)?)
    try Tokens.verify(token, "wrong", 101)?; h.fail("accepted wrong signature") end
    try Tokens.verify(token, "secret", 2_592_100)?; h.fail("accepted expired token") end
    try Tokens.verify(token + "x", "secret", 101)?; h.fail("accepted corrupt token") end
    try Tokens.verify("e30.e30.", "secret", 101)?; h.fail("accepted unsigned token") end
    let header: String = Base64.encode_url("""{"alg":"HS512"}""")
    let parts = token.split(".")
    let message: String = header + "." + parts(1)?
    let forged: String = message + "." + Base64.encode_url(HmacSha256("secret", message)?)
    try Tokens.verify(forged, "secret", 101)?
      h.fail("accepted wrong algorithm with a valid HMAC")
    end

class iso _Fields is UnitTest
  fun name(): String => "typed-entities-and-json"
  fun apply(h: TestHelper) ? =>
    let row = pg.Row(recover val
      [pg.Field("id", I64(123))
       pg.Field("username", "pony")
       pg.Field("email", "pony@example.com")
       pg.Field("bio", None)
       pg.Field("image", None)]
    end)
    let user = User.from_row(row)?
    h.assert_eq[I64](123, user.id)
    h.assert_true(user.bio is None)
    h.assert_true(user.image is None)
    h.assert_eq[String]("token", user.json("token")("token")? as String)
    h.assert_false(user.json("token").contains("password_hash"))
    let tags = Fields.text_array(recover val ["a"; "z"] end)
    let article_row = pg.Row(recover val
      [pg.Field("id", I64(42))
       pg.Field("slug", "pony-42")
       pg.Field("title", "Pony")
       pg.Field("description", "Description")
       pg.Field("body", None)
       pg.Field("created_at", pg.PgTimestamp(0))
       pg.Field("updated_at", pg.PgTimestamp(999_999))
       pg.Field("tag_list", tags)
       pg.Field("favorites_count", I64(2))
       pg.Field("favorited", true)
       pg.Field("username", "pony")
       pg.Field("bio", None)
       pg.Field("image", "image")
       pg.Field("following", false)]
    end)
    let article = Article.from_row(article_row)?
    let obj = article.json()?
    h.assert_eq[I64](2, obj("favoritesCount")? as I64)
    h.assert_true(obj("favorited")? as Bool)
    h.assert_eq[String]("a", (obj("tagList")? as JSONArray)(0)? as String)
    h.assert_false(obj.contains("body"))
    h.assert_false(obj.contains("id"))
    let followed = Profile.with_following(article.author, true)
    h.assert_true(followed.following)
    h.assert_false(article.author.following)
    let comment_row = pg.Row(recover val
      [pg.Field("id", I64(9))
       pg.Field("body", "Comment")
       pg.Field("created_at", pg.PgTimestamp(0))
       pg.Field("updated_at", pg.PgTimestamp(0))
       pg.Field("username", "pony")
       pg.Field("bio", None)
       pg.Field("image", None)
       pg.Field("following", false)]
    end)
    let comment = Comment.from_row(comment_row)?
    h.assert_eq[I64](9, comment.json()?("id")? as I64)
    h.assert_eq[String]("Comment", comment.body)
    try
      User.from_row(pg.Row(recover val [pg.Field("id", "not an integer")] end))?
      h.fail("accepted an invalid database row")
    end

class iso _Timestamps is UnitTest
  fun name(): String => "utc-millisecond-timestamps"
  fun apply(h: TestHelper) ? =>
    h.assert_eq[String]("2000-01-01T00:00:00.000Z", Timestamp(pg.PgTimestamp(0))?)
    h.assert_eq[String]("2000-01-01T00:00:00.999Z", Timestamp(pg.PgTimestamp(999_999))?)
    h.assert_eq[String]("2000-01-01T00:00:00.001Z", Timestamp(pg.PgTimestamp(1_000))?)
    h.assert_eq[String]("1999-12-31T23:59:59.999Z", Timestamp(pg.PgTimestamp(-1))?)
    h.assert_eq[String]("2000-02-29T00:00:00.000Z",
      Timestamp(pg.PgTimestamp(5_097_600_000_000))?)
    try Timestamp(pg.PgTimestamp(I64.max_value()))?; h.fail("accepted infinity") end

class iso _Passwords is UnitTest
  fun name(): String => "bcrypt-cost-10"
  fun apply(h: TestHelper) ? =>
    let hash' = Password.hash("password")?
    h.assert_eq[String]("$2b$10$", hash'.substring(0, 7))
    h.assert_true(Password.verify("password", hash')?)
    h.assert_false(Password.verify("wrong", hash')?)
    h.assert_true(hash' != Password.hash("password")?)
    try Password.hash(String.from_array(recover val Array[U8].init('x', 73) end))?
      h.fail("accepted password above bcrypt byte limit")
    end
