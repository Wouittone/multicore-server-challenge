use "collections"
use "json"
use hobby = "hobby"
use stallion = "stallion"
use pg = "postgres"

primitive Errors
  fun body(message: String): String =>
    JSONObject.update("errors",
      JSONObject.update("body", JSONArray.push(message))).print()

actor Request is (hobby.HandlerReceiver & pg.ResultReceiver)
  embed _handler: hobby.RequestHandler
  let _route: String
  let _pool: Pool
  let _secret: String
  let _err: OutStream
  var _session: (pg.Session | None) = None
  var _state: String = ""
  var _viewer: I64 = 0
  var _token: String = ""
  var _key: String = ""
  var _comment_id: I64 = 0
  var _id: I64 = 0
  var _input: JSONObject = JSONObject
  var _params: Array[pg.FieldDataTypes] val =
    recover val Array[pg.FieldDataTypes] end
  var _tags: Array[String] val = recover val Array[String] end
  var _filter: String = ""
  var _filter_value: String = ""
  var _articles: Array[Article] val = recover val Array[Article] end
  var _profile: (Profile | None) = None
  var _transaction: Bool = false
  var _finished: Bool = false
  var _failure_status: stallion.Status = stallion.StatusUnprocessableEntity

  new create(ctx: hobby.HandlerContext iso, route: String, pool: Pool,
    secret: String, err: OutStream)
  =>
    _handler = hobby.RequestHandler(consume ctx)
    _route = route
    _pool = pool
    _secret = secret
    _err = err
    _start()

  be _start() =>
    if not _authenticate() then return end
    try
      if (_route == "profile") or (_route == "follow") or
        (_route == "unfollow")
      then
        _key = Input.decode(_handler.param("username")?)?
      elseif (_route == "article") or (_route == "update") or
        (_route == "delete") or (_route == "favorite") or
        (_route == "unfavorite") or (_route == "comments") or
        (_route == "comment-create") or (_route == "comment-delete")
      then
        _key = Input.decode(_handler.param("slug")?)?
      end
      if _route == "comment-delete" then
        try _comment_id = Input.integer(Input.decode(_handler.param("id")?)?)?
        else _error(stallion.StatusNotFound); return
        end
      end
      _prepare()?
    else
      _error(_failure_status)
      return
    end
    _pool.acquire(this)

  fun ref _authenticate(): Bool =>
    if (_route == "tags") or (_route == "register") or (_route == "login") then
      return true
    end
    let optional = (_route == "list") or (_route == "profile") or
      (_route == "article") or (_route == "comments")
    match _handler.request().headers.get("Authorization")
    | let header: String =>
      try
        if header.substring(0, 6) != "Token " then error end
        _token = header.substring(6)
        _viewer = Tokens.verify(_token, _secret)?
        true
      else
        _error(stallion.StatusUnauthorized)
        false
      end
    | None =>
      if optional then true
      else _error(stallion.StatusUnauthorized); false
      end
    end

  fun ref _prepare() ? =>
    match _route
    | "register" | "login" | "user-update" =>
      _input = _body("user")?
      if _route == "register" then
        let username = Input.required(_input, "username")?
        let email = Input.required(_input, "email")?
        let password = Input.required(_input, "password")?
        let hash' = _hash(password)?
        _params = recover val [as pg.FieldDataTypes: username; email; hash'] end
      elseif _route == "login" then
        let email = Input.required(_input, "email")?
        let password = Input.required(_input, "password")?
        if password.size() > 72 then error end
        _params = recover val [as pg.FieldDataTypes: email] end
      else
        let email = Input.nonempty(_input, "email")?
        let username = Input.nonempty(_input, "username")?
        let password = Input.nonempty(_input, "password")?
        let hash': (String | None) =
          match password
          | let p: String => _hash(p)?
          else None
          end
        let bio = Input.optional(_input, "bio")?
        let image = Input.optional(_input, "image")?
        let viewer = _viewer
        _params = recover val
          [as pg.FieldDataTypes: viewer; email; username; hash'; bio; image]
        end
      end
    | "create" | "update" =>
      _input = _body("article")?
      if _route == "create" then
        let title = Input.required(_input, "title")?
        let description = Input.required(_input, "description")?
        let body = Input.required(_input, "body")?
        let viewer = _viewer
        _params = recover val
          [as pg.FieldDataTypes: viewer; title; description; body]
        end
        if _input.get_or_else("tagList", None) isnt None then
          let tags = _input("tagList")? as JSONArray
          let strings = recover iso Array[String](tags.size()) end
          for value in tags.values() do
            let tag' = value as String
            if (tag'.size() == 0) or tag'.contains(
              String.from_array(recover val [U8(0)] end))
            then error
            end
            strings.push(tag')
          end
          _tags = consume strings
        end
      else
        // Validate optional fields before acquiring a connection.
        Input.nonempty(_input, "title")?
        Input.nonempty(_input, "description")?
        Input.nonempty(_input, "body")?
      end
    | "comment-create" =>
      _input = _body("comment")?
      Input.required(_input, "body")?
    | "list" | "feed" =>
      let raw = match _handler.request().uri.query
        | let s: String => s
        else ""
        end
      let query = Input.query(raw)?
      let limit' = Input.integer(try query("limit")? else "20" end)?
      let offset = Input.integer(try query("offset")? else "0" end)?
      if (limit' < 1) or (limit' > 100) then error end
      if _route == "feed" then _filter = "feed"
      else
        for filter in (recover val ["tag"; "author"; "favorited"] end).values() do
          try
            _filter_value = query(filter)?
            if _filter_value.size() == 0 then continue end
            _filter = filter
            break
          end
        end
      end
      let viewer = _viewer
      let lim = limit'.i32()
      let off = offset
      if (_filter == "") or (_filter == "feed") then
        _params = recover val [as pg.FieldDataTypes: viewer; lim; off] end
      else
        let filter_value = _filter_value
        _params = recover val
          [as pg.FieldDataTypes: viewer; lim; off; filter_value]
        end
      end
    end

  fun _body(key: String): JSONObject ? =>
    let source: String = String.from_array(_handler.body())
    let obj = JSONParser.parse(source) as JSONObject
    obj(key)? as JSONObject

  fun ref _hash(password: String): String ? =>
    Password.validate(password)?
    try
      Password.hash(password)?
    else
      _err.print("bcrypt hashing failed")
      _failure_status = stallion.StatusInternalServerError
      error
    end

  be connected(session: pg.Session) =>
    _session = session
    let viewer = _viewer
    let key = _key
    match _route
    | "tags" => _query("tags", "SELECT name FROM tags ORDER BY name")
    | "register" =>
      _query("user-result",
        "INSERT INTO users (username, email, password_hash) VALUES ($1,$2,$3) RETURNING " +
        SQL.user_fields(), _params)
    | "login" =>
      _query("login-result", "SELECT " + SQL.user_fields() +
        ", password_hash FROM users WHERE email = $1", _params)
    | "user" =>
      _query("user-result", "SELECT " + SQL.user_fields() +
        " FROM users WHERE id = $1",
        recover val [as pg.FieldDataTypes: viewer] end)
    | "user-update" =>
      _query("user-result",
        "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), " +
          "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), " +
          "image = COALESCE($6, image) WHERE id = $1 RETURNING " +
        SQL.user_fields(), _params)
    | "profile" =>
      _query("profile", "SELECT " + SQL.profile(SQL.follows()) +
        " FROM users u WHERE u.username = $2",
        recover val [as pg.FieldDataTypes: viewer; key] end)
    | "follow" | "unfollow" =>
      _query("follow-target", "SELECT u.id, " + SQL.profile("false") +
        " FROM users u WHERE u.username = $1",
        recover val [as pg.FieldDataTypes: key] end)
    | "list" | "feed" => _query("page", SQL.page(_filter), _params)
    | "article" =>
      _query("article", SQL.article() + "WHERE a.slug = $2",
        recover val [as pg.FieldDataTypes: viewer; key] end)
    | "create" => _query("begin", "BEGIN")
    | "update" | "delete" =>
      _query("owner", "SELECT id, author_id FROM articles WHERE slug = $1",
        recover val [as pg.FieldDataTypes: key] end)
    | "favorite" | "unfavorite" | "comments" | "comment-create" =>
      _query("article-id", "SELECT id FROM articles WHERE slug = $1",
        recover val [as pg.FieldDataTypes: key] end)
    | "comment-delete" =>
      let comment_id = _comment_id
      _query("comment-owner",
        "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id " +
          "WHERE c.id = $1 AND a.slug = $2 ",
        recover val [as pg.FieldDataTypes: comment_id; key] end)
    end

  fun ref _query(state: String, sql: String,
    params: Array[pg.FieldDataTypes] val =
      recover val Array[pg.FieldDataTypes] end)
  =>
    _state = state
    match _session
    | let session: pg.Session =>
      session.execute(pg.PreparedQuery(sql, params), this)
    end

  be pg_query_result(session: pg.Session, result: pg.Result) =>
    try
      _result(result)?
    else
      _err.print("Request processing failed in state " + _state)
      _abort(stallion.StatusInternalServerError)
    end

  fun ref _result(result: pg.Result) ? =>
    let viewer = _viewer
    let id = _id
    match _state
    | "tags" =>
      var tags = JSONArray
      for row in (result as pg.ResultSet).rows().values() do
        tags = tags.push(Fields.text(row, 0)?)
      end
      _respond(stallion.StatusOK, JSONObject.update("tags", tags))
    | "user-result" | "login-result" =>
      let rows = (result as pg.ResultSet).rows()
      if rows.size() == 0 then _error(stallion.StatusUnauthorized); return end
      let row = rows(0)?
      let user = User.from_row(row, _route == "login")?
      var token = _token
      if (_route == "register") or (_route == "login") then
        if _route == "login" then
          if not Password.verify(Input.required(_input, "password")?,
            user.password_hash as String)?
          then
            _error(stallion.StatusUnauthorized)
            return
          end
        end
        token = Tokens.issue(user.id, _secret)?
      end
      _respond(if _route == "register" then stallion.StatusCreated
        else stallion.StatusOK end,
        JSONObject.update("user", user.json(token)))
    | "profile" =>
      let rows = (result as pg.ResultSet).rows()
      if rows.size() == 0 then _error(stallion.StatusNotFound); return end
      let profile = Profile.from_row(rows(0)?)?
      _respond(stallion.StatusOK, JSONObject.update("profile", profile.json()))
    | "article" =>
      let rows = (result as pg.ResultSet).rows()
      if rows.size() == 0 then _error(stallion.StatusNotFound); return end
      let article = Article.from_row(rows(0)?)?
      _respond(if _route == "create" then stallion.StatusCreated
        else stallion.StatusOK end,
        JSONObject.update("article", article.json()?))
    | "comment" =>
      let rows = (result as pg.ResultSet).rows()
      let comment = Comment.from_row(rows(0)?)?
      _respond(stallion.StatusCreated,
        JSONObject.update("comment", comment.json()?))
    | "page" =>
      let articles = recover iso Array[Article] end
      for row in (result as pg.ResultSet).rows().values() do
        articles.push(Article.from_row(row)?)
      end
      _articles = consume articles
      let value = _filter_value
      let params: Array[pg.FieldDataTypes] val =
        if _filter == "feed" then
          recover val [as pg.FieldDataTypes: viewer] end
        elseif _filter == "" then
          recover val Array[pg.FieldDataTypes] end
        else
          recover val [as pg.FieldDataTypes: value] end
        end
      _query("count", SQL.count(_filter), params)
    | "count" =>
      let count = Fields.id((result as pg.ResultSet).rows()(0)?)?
      var articles = JSONArray
      for article in _articles.values() do
        articles = articles.push(article.json()?)
      end
      _respond(stallion.StatusOK, JSONObject.update("articles", articles)
        .update("articlesCount", count))
    | "follow-target" =>
      let rows = (result as pg.ResultSet).rows()
      if rows.size() == 0 then _error(stallion.StatusNotFound); return end
      let target = Fields.id(rows(0)?)?
      _profile = Profile.from_row(rows(0)?, 1)?
      _query("follow-write",
        if _route == "follow" then
          "INSERT INTO follows (follower_id, followee_id) " +
            "VALUES ($1,$2) ON CONFLICT DO NOTHING "
        else "DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2"
        end, recover val [as pg.FieldDataTypes: viewer; target] end)
    | "follow-write" =>
      _respond(stallion.StatusOK, JSONObject.update("profile",
        Profile.with_following(_profile as Profile, _route == "follow").json()))
    | "begin" =>
      _transaction = true
      _query("insert",
        "INSERT INTO articles (id, slug, author_id, title, description, body) " +
          "SELECT n.id, " + SQL.slug("$2") + "|| '-' || n.id, $1,$2,$3,$4 " +
          "FROM (SELECT nextval(pg_get_serial_sequence('articles','id')) AS id) n " +
          "RETURNING id ", _params)
    | "insert" =>
      _id = Fields.id((result as pg.ResultSet).rows()(0)?)?
      let tags = Fields.text_array(_tags)
      if tags.size() == 0 then _query("commit", "COMMIT")
      else
        _query("tags-insert",
          "INSERT INTO tags (name) " +
            "SELECT DISTINCT unnest($1::text[]) " +
            "ON CONFLICT (name) DO NOTHING ",
          recover val [as pg.FieldDataTypes: tags] end)
      end
    | "tags-insert" =>
      let tags = Fields.text_array(_tags)
      _query("tags-link",
        "INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t " +
          "WHERE t.name = ANY($2::text[]) ",
        recover val [as pg.FieldDataTypes: id; tags] end)
    | "tags-link" => _query("commit", "COMMIT")
    | "commit" =>
      _transaction = false
      _full_article()
    | "rollback" =>
      _transaction = false
      _error(_failure_status)
    | "owner" =>
      let rows = (result as pg.ResultSet).rows()
      if rows.size() == 0 then _error(stallion.StatusNotFound); return end
      if Fields.id(rows(0)?, 1)? != viewer then
        _error(stallion.StatusForbidden)
        return
      end
      _id = Fields.id(rows(0)?)?
      let article_id = _id
      if _route == "delete" then
        _query("deleted", "DELETE FROM articles WHERE id = $1",
          recover val [as pg.FieldDataTypes: article_id] end)
      else
        let title = Input.nonempty(_input, "title")?
        let description = Input.nonempty(_input, "description")?
        let body = Input.nonempty(_input, "body")?
        _query("article-write",
          "UPDATE articles SET title = COALESCE($2, title), " +
            "description = COALESCE($3, description), body = COALESCE($4, body), " +
            "slug = CASE WHEN $2::text IS NULL THEN slug ELSE " +
          SQL.slug("$2") + "|| '-' || id END, updated_at = now() " +
            "WHERE id = $1 ",
          recover val [as pg.FieldDataTypes: article_id; title; description; body] end)
      end
    | "article-id" =>
      let rows = (result as pg.ResultSet).rows()
      if rows.size() == 0 then _error(stallion.StatusNotFound); return end
      _id = Fields.id(rows(0)?)?
      let article_id = _id
      match _route
      | "favorite" | "unfavorite" =>
        _query("article-write",
          if _route == "favorite" then
            "INSERT INTO favorites (user_id, article_id) " +
              "VALUES ($1,$2) ON CONFLICT DO NOTHING "
          else "DELETE FROM favorites WHERE user_id = $1 AND article_id = $2"
          end, recover val [as pg.FieldDataTypes: viewer; article_id] end)
      | "comments" =>
        _query("comments",
          SQL.comment(SQL.follows()) +
          "FROM comments c JOIN users u ON u.id = c.author_id " +
            "WHERE c.article_id = $2 ORDER BY c.created_at DESC, c.id DESC LIMIT 100 ",
          recover val [as pg.FieldDataTypes: viewer; article_id] end)
      | "comment-create" =>
        let body = Input.required(_input, "body")?
        _query("comment",
          "WITH c AS (INSERT INTO comments (article_id, author_id, body) " +
            "VALUES ($1,$2,$3) RETURNING id, body, created_at, updated_at, author_id) " +
          SQL.comment("false") + "FROM c JOIN users u ON u.id = c.author_id",
          recover val [as pg.FieldDataTypes: article_id; viewer; body] end)
      end
    | "article-write" => _full_article()
    | "comments" =>
      var comments = JSONArray
      for row in (result as pg.ResultSet).rows().values() do
        let comment = Comment.from_row(row)?
        comments = comments.push(comment.json()?)
      end
      _respond(stallion.StatusOK, JSONObject.update("comments", comments))
    | "comment-owner" =>
      let rows = (result as pg.ResultSet).rows()
      if rows.size() == 0 then _error(stallion.StatusNotFound); return end
      if Fields.id(rows(0)?)? != viewer then
        _error(stallion.StatusForbidden)
        return
      end
      let comment_id = _comment_id
      _query("deleted", "DELETE FROM comments WHERE id = $1",
        recover val [as pg.FieldDataTypes: comment_id] end)
    | "deleted" => _finish(stallion.StatusNoContent, "")
    else error
    end

  fun ref _full_article() =>
    let viewer = _viewer
    let id = _id
    _query("article", SQL.article() + "WHERE a.id = $2",
      recover val [as pg.FieldDataTypes: viewer; id] end)

  be pg_query_failed(session: pg.Session, query: pg.Query,
    failure: (pg.ErrorResponseMessage | pg.ClientQueryError))
  =>
    var status: stallion.Status = stallion.StatusInternalServerError
    match failure
    | let err: pg.ErrorResponseMessage =>
      _err.print("PostgreSQL error " + err.code + " in state " + _state)
      if err.code == "23505" then status = stallion.StatusUnprocessableEntity end
    else
      _err.print("PostgreSQL connection/query failure in state " + _state)
    end
    if _state == "rollback" then
      session.close()
      _session = None
      _error(stallion.StatusInternalServerError)
    else
      _abort(status)
    end

  fun ref _abort(status: stallion.Status) =>
    if _transaction then
      _failure_status = status
      _query("rollback", "ROLLBACK")
    else
      _error(status)
    end

  fun ref _respond(status: stallion.Status, obj: JSONObject) =>
    _finish(status, obj.print())

  fun ref _error(status: stallion.Status) =>
    _finish(status, Errors.body("Request failed"))

  fun ref _finish(status: stallion.Status, body: String) =>
    if _finished then return end
    _finished = true
    _handler.respond(status, body)
    match _session
    | let session: pg.Session => _pool.release(session)
    end
    _session = None

  be unavailable() =>
    _error(stallion.StatusServiceUnavailable)

  // A disconnected HTTP client does not cancel an in-flight write: finish
  // the query/transaction before returning the session to the pool.
  be dispose() => None
  be throttled() => None
  be unthrottled() => None
