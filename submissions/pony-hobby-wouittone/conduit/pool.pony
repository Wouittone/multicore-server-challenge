use "collections"
use "net"
use pg = "postgres"

actor Pool is pg.SessionStatusNotify
  let _idle: Array[pg.Session] = Array[pg.Session]
  let _all: Array[pg.Session] = Array[pg.Session]
  let _waiting: Array[Request] = Array[Request]
  let _err: OutStream
  var _failed: Bool = false

  new create(auth: TCPConnectAuth, host: String, port: String,
    user: String, password: String, database: String, err: OutStream)
  =>
    _err = err
    // One process, 32 sessions, no extra cancellation connections.
    for i in Range(0, 32) do
      _all.push(pg.Session(
        pg.ServerConnectInfo(auth, host, port
          where auth_requirement' = pg.AllowAnyAuth),
        pg.DatabaseConnectInfo(user, password, database), this))
    end

  be acquire(request: Request) =>
    if _failed then
      request.unavailable()
    elseif _idle.size() > 0 then
      try request.connected(_idle.pop()?) end
    elseif _waiting.size() >= 4096 then
      request.unavailable()
    else
      _waiting.push(request)
    end

  be release(session: pg.Session) =>
    if _failed then
      session.close()
    elseif _waiting.size() > 0 then
      try _waiting.shift()?.connected(session) end
    else
      _idle.push(session)
    end

  be pg_session_authenticated(session: pg.Session) =>
    release(session)

  be pg_session_connection_failed(session: pg.Session,
    reason: pg.ConnectionFailureReason)
  =>
    _err.print("PostgreSQL connection failed; service unavailable")
    _fail()

  be pg_session_shutdown(session: pg.Session) =>
    _err.print("PostgreSQL session closed; service unavailable")
    _fail()

  be dispose() =>
    _fail()
    for session in _all.values() do session.close() end
    _all.clear()

  fun ref _fail() =>
    if _failed then return end
    _failed = true
    for request in _waiting.values() do request.unavailable() end
    _waiting.clear()
    for session in _idle.values() do session.close() end
    _idle.clear()
