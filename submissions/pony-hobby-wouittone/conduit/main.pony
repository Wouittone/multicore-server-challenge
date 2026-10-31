use "cli"
use "net"
use "uri"
use hobby = "hobby"
use stallion = "stallion"

actor Main is hobby.ServerNotify
  let _env: Env
  var _pool: (Pool | None) = None

  new create(env: Env) =>
    _env = env
    try
      let vars = EnvVars(env.vars)
      let url = ParseURI(vars("DATABASE_URL")?) as URI
      let secret = vars("JWT_SECRET")?
      if secret.size() == 0 then error end
      let scheme = url.scheme as String
      if (scheme != "postgres") and (scheme != "postgresql") then error end
      let authority = url.authority as URIAuthority
      let credentials = authority.userinfo as String
      let separator = try credentials.find(":")? else -1 end
      let user = Input.decode(
        if separator < 0 then credentials
        else credentials.substring(0, separator)
        end)?
      let password =
        if separator < 0 then ""
        else Input.decode(credentials.substring(separator + 1))?
        end
      let database = Input.decode(url.path.substring(1))?
      if (user.size() == 0) or (database.size() == 0) then error end
      let dbhost =
        if authority.host.substring(0, 1) == "[" then
          authority.host.substring(1, authority.host.size().isize() - 1)
        else authority.host
        end
      let dbport = match authority.port
        | let p: U16 => p.string()
        else "5432"
        end
      let pool = Pool(TCPConnectAuth(env.root), dbhost, dbport,
        user, password, database, env.err)
      _pool = pool
      let app = Routes(pool, secret, env.err)
      let host = try vars("HOST")? else "127.0.0.1" end
      let port = try vars("PORT")? else "3000" end
      match app.build()
      | let built: hobby.BuiltApplication =>
        hobby.Server(TCPListenAuth(env.root), built, this
          where host = host, port = port,
          config = stallion.ServerConfig(host, port where idle_timeout' = None))
      | let err: hobby.ConfigError =>
        env.err.print(err.message)
        pool.dispose()
        env.exitcode(1)
      end
    else
      env.err.print("Invalid configuration: DATABASE_URL and JWT_SECRET are required")
      env.exitcode(1)
    end

  be listening(server: hobby.Server, host: String, service: String) =>
    _env.out.print("conduit (Pony/Hobby) listening on " + host + ":" + service)

  be listen_failed(server: hobby.Server, reason: String) =>
    _env.err.print(reason)
    _env.exitcode(1)
    server.dispose()
    match _pool
    | let pool: Pool => pool.dispose()
    end

  be connection_failed(server: hobby.Server, reason: String) =>
    _env.err.print(reason)

primitive Routes
  fun apply(pool: Pool, secret: String, err: OutStream): hobby.Application =>
    let app = hobby.Application
    app.add_response_interceptor(JSONResponses)
    app.get("/api/tags", Factory("tags", pool, secret, err))
    app.post("/api/users", Factory("register", pool, secret, err))
    app.post("/api/users/login", Factory("login", pool, secret, err))
    app.get("/api/user", Factory("user", pool, secret, err))
    app.put("/api/user", Factory("user-update", pool, secret, err))
    app.get("/api/profiles/:username", Factory("profile", pool, secret, err))
    app.post("/api/profiles/:username/follow", Factory("follow", pool, secret, err))
    app.delete("/api/profiles/:username/follow", Factory("unfollow", pool, secret, err))
    app.get("/api/articles", Factory("list", pool, secret, err))
    app.get("/api/articles/feed", Factory("feed", pool, secret, err))
    app.post("/api/articles", Factory("create", pool, secret, err))
    app.get("/api/articles/:slug", Factory("article", pool, secret, err))
    app.put("/api/articles/:slug", Factory("update", pool, secret, err))
    app.delete("/api/articles/:slug", Factory("delete", pool, secret, err))
    app.post("/api/articles/:slug/favorite", Factory("favorite", pool, secret, err))
    app.delete("/api/articles/:slug/favorite", Factory("unfavorite", pool, secret, err))
    app.get("/api/articles/:slug/comments", Factory("comments", pool, secret, err))
    app.post("/api/articles/:slug/comments", Factory("comment-create", pool, secret, err))
    app.delete("/api/articles/:slug/comments/:id", Factory("comment-delete", pool, secret, err))
    app

class val Factory is hobby.HandlerFactory
  let _route: String
  let _pool: Pool
  let _secret: String
  let _err: OutStream

  new val create(route: String, pool: Pool, secret: String, err: OutStream) =>
    _route = route
    _pool = pool
    _secret = secret
    _err = err

  fun apply(ctx: hobby.HandlerContext iso) =>
    Request(consume ctx, _route, _pool, _secret, _err)

primitive JSONResponses is hobby.ResponseInterceptor
  fun apply(ctx: hobby.ResponseContext ref) =>
    if ctx.status() is stallion.StatusNotFound then
      ctx.set_body(Errors.body("Not found"))
    end
    ctx.set_header("Content-Type", "application/json")
