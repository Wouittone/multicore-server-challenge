# Pony / Hobby Conduit

Front: nginx

An actor-per-request implementation of all 19 endpoints in `SPEC.md`, targeting
Ubuntu 24.04 x86_64. The server runs as one process and reads `DATABASE_URL`,
`JWT_SECRET`, `HOST`, and `PORT`. Host and port default to `127.0.0.1:3000`.

## Stack

| Component | Pin |
| --- | --- |
| Pony compiler and standard library | 0.77.2 |
| Corral | 0.9.2 |
| Hobby | 0.18.0 |
| Stallion | `c4a920667426978f0df46a0942d21753c646d1f5` |
| Pure Pony PostgreSQL driver | `6445c156581b13084587aeaed543d846d15fe146` |
| JSON, URI, Base64, actors, networking | Pony standard library |
| HS256 and secure random bytes | Standard-library `crypto`, OpenSSL 3 C FFI |
| bcrypt cost 10 | Linux libxcrypt / Windows Openwall crypt_blowfish, reentrant C FFI |

`lock.json` pins every downloaded Pony dependency. The Stallion pin is the
upstream fix for a test parameter shadowing `UnitTest.label`. The PostgreSQL pin
is the upstream fix for the standard library's partial MD5/SHA256 API. These
commits preserve compatibility with the released compiler; the latest Hobby
and PostgreSQL releases document a requirement for the unreleased ponyc 0.78.0.
No dependency sources are patched by the build.

All JSON request parsing, response envelopes, errors, JWT claims, and final
serialization use the standard-library `json` package (`JSONObject`,
`JSONArray`, `JSONParser`), not an external JSON library. PostgreSQL returns
typed columns, native text arrays, and binary timestamps. Immutable Pony
`User`, `Profile`, `Article`, and `Comment` entities decode those rows and
serialize responses in the Hobby request handlers. SQL does not construct JSON.

## Design

- Hobby/Stallion handle HTTP/1.1 and keep-alive. Idle connection expiry is
  disabled, so Nginx's 60-second upstream keep-alive cannot race a shorter
  server-side timeout.
- A pool actor leases 32 PostgreSQL sessions exclusively to request actors.
  Only the lease manager is serialized; SQL executes asynchronously and requests
  run concurrently across Pony schedulers. The waiting queue is bounded at
  4,096 requests; overload and connection failures return JSON 503 errors.
  There are no extra cancellation connections, processes, or data caches.
- Every SQL parameter is bound through the driver's extended query protocol.
  Lists use the reference index-friendly queries, newest-first ordering,
  tag/author/favorited precedence, capped counts, and the lateral feed query.
- Article/tag creation holds its lease through `BEGIN`, inserts, and `COMMIT`.
  Failures roll back before the lease is returned. A disconnected HTTP client
  does not prematurely return a session containing an in-flight write.
- Pony formats UTC timestamps with truncation and exactly three fractional
  digits, including pre-2000 dates. Null database fields remain JSON null.
- JWT signatures, HS256 algorithm, and expiration are verified on every
  authenticated request. Passwords use fresh random bcrypt salts and cost 10.
  Neither verification nor database results are cached.

The only application C FFI is bcrypt through `crypt_gensalt_rn`/`crypt_rn`
on Linux and Openwall's reentrant bcrypt functions on Windows.
The standard library uses OpenSSL C FFI for cryptography and TLS support.

## Build and run

On Ubuntu 24.04, from the repository root:

```bash
sudo bash submissions/pony-hobby-wouittone/install.sh
bash submissions/pony-hobby-wouittone/build.sh
bash test/run.sh submissions/pony-hobby-wouittone
```

`install.sh` installs the pinned official toolchain releases under versioned
`/opt/conduit-*` paths, checks the published SHA-512 checksums, and installs
Ubuntu's OpenSSL/libxcrypt development packages. `build.sh` fetches the locked
Pony sources, builds the server and unit tests, and runs those tests.
`start.sh` execs the server in the foreground without modifying configuration.

On Windows, with Git for Windows (including its OpenSSL 3 DLLs):

```powershell
.\submissions\pony-hobby-wouittone\build.ps1
```

The script restores missing pinned Pony tools and Zig 0.15.1, builds Openwall
crypt_blowfish at revision `3354bb81eea489e972b0a7c63231514ab34f73a0` for the
MSVC ABI, generates OpenSSL import libraries, and builds the server and tests.
Pass `-OpenSSLDirectory` to use another OpenSSL 3 DLL installation.
Tool archives and native build products stay in ignored `bin/` directories.

## Verification

The native Windows server build and all six unit tests pass: standard-library
JSON, input validation, HS256 JWTs, typed entities, UTC timestamps, and bcrypt.
The push workflow runs the same Windows build plus the full challenge
conformance suite against a fresh PostgreSQL 18 database on Ubuntu 24.04.
No performance score is claimed.

## Performance measurements

`benchmark.sh` runs the repository's official load generator against the full
seed in the push workflow. It probes 500, 2,000, 5,000, and 10,000 users with
30-second ramps and 60-second measurement windows, stopping on a failing or
load-generator-limited probe. The highest eligible passing probe receives a
60-second ramp and a five-minute hold. Raw histograms, merged endpoint metrics,
environment details, and server logs are uploaded as `pony-hobby-performance`.
Capacity failures are measurement outcomes, not workflow errors.

For a local Windows measurement, run `benchmark.ps1` after `build.ps1`, providing
PostgreSQL 18's binary directory with `-PostgresBin` and Go >= 1.27.1 with `-Go`.
It creates an isolated, loopback-only PostgreSQL cluster on port 55439 and a dev
seed (100,000 users, 10,000 articles) under ignored `bin/`. It runs the same
probes and hold, then stops its own server and database processes. The cluster
and results are retained; it refuses to overwrite an existing cluster.

These are **performance screens, not leaderboard scores**: the application,
PostgreSQL, and load generator share one machine, Windows uses the smaller
seed, and GitHub runners are shared infrastructure. Both tests access Hobby
directly, without Nginx, whereas the submitted configuration declares Nginx.
The probe ceiling is a test budget, not proof of the server's maximum capacity.
Raw verdicts retain load-generator limitation indicators; Windows does not
provide the Linux `/proc/stat` whole-machine CPU measurement.
