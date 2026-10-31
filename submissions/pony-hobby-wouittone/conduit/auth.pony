use "crypto"
use "encode/base64"
use "json"
use "time"

use "lib:crypt" if linux
use @crypt_gensalt_rn[Pointer[U8]](
  prefix: Pointer[U8] tag, count: ULong, random: Pointer[U8] tag,
  random_size: I32, output: Pointer[U8] tag, output_size: I32) if linux
use @crypt_rn[Pointer[U8]](
  password: Pointer[U8] tag, salt: Pointer[U8] tag,
  data: Pointer[U8] tag, size: I32) if linux
use "lib:conduit_bcrypt" if windows
use @_crypt_gensalt_blowfish_rn[Pointer[U8]](
  prefix: Pointer[U8] tag, count: ULong, random: Pointer[U8] tag,
  random_size: I32, output: Pointer[U8] tag, output_size: I32) if windows
use @_crypt_blowfish_rn[Pointer[U8]](
  password: Pointer[U8] tag, salt: Pointer[U8] tag,
  output: Pointer[U8] tag, output_size: I32) if windows

primitive Password
  fun hash(password: String): String ? =>
    validate(password)?
    let entropy = RandBytes(16)?
    let salt = recover iso Array[U8].init(0, 128) end
    let ptr =
      ifdef linux then
        @crypt_gensalt_rn("$2b$".cpointer(), 10, entropy.cpointer(),
        16, salt.cpointer(), 128).is_null()
      elseif windows then
        @_crypt_gensalt_blowfish_rn("$2b$".cpointer(), 10, entropy.cpointer(),
          16, salt.cpointer(), 128).is_null()
      else
        error
      end
    if ptr then error end
    _crypt(password, String.from_array(consume salt))?

  fun verify(password: String, hash': String): Bool ? =>
    validate(password)?
    if (hash'.size() != 60) or
      ((hash'.substring(0, 4) != "$2a$") and
      (hash'.substring(0, 4) != "$2b$") and
      (hash'.substring(0, 4) != "$2y$"))
    then
      error
    end
    ConstantTimeCompare(_crypt(password, hash')?, hash')

  fun validate(password: String) ? =>
    // bcrypt's input is limited to 72 bytes; never silently truncate it.
    if (password.size() == 0) or (password.size() > 72) or
      password.contains(String.from_array(recover val [U8(0)] end))
    then
      error
    end

  fun _crypt(password: String, salt: String): String ? =>
    // libxcrypt's crypt_data is 32768 bytes; both backends check the size.
    let scratch = Array[U8].init(0, 32768)
    let ptr =
      ifdef linux then
        @crypt_rn(password.cpointer(), salt.cpointer(),
          scratch.cpointer(), 32768)
      elseif windows then
        @_crypt_blowfish_rn(password.cpointer(), salt.cpointer(),
          scratch.cpointer(), 32768)
      else
        error
      end
    if ptr.is_null() then error end
    let result = String.copy_cstring(ptr).clone()
    if result.size() != 60 then error end
    consume result

primitive Tokens
  fun issue(id: I64, secret: String, now: I64 = Time.seconds()): String ? =>
    let header: String = Base64.encode_url("""{"alg":"HS256","typ":"JWT"}""")
    let claims = JSONObject.update("sub", id.string())
      .update("iat", now).update("exp", now + 2_592_000)
    let payload: String = Base64.encode_url(claims.print())
    let message: String = header + "." + payload
    message + "." + Base64.encode_url(HmacSha256(secret, message)?)

  fun verify(token: String, secret: String,
    now: I64 = Time.seconds()): I64 ?
  =>
    let parts = token.split(".")
    if parts.size() != 3 then error end
    let header = _decode(parts(0)?)?
    let payload = _decode(parts(1)?)?
    let signature = _decode(parts(2)?)?
    let obj = JSONParser.parse(String.from_array(header)) as JSONObject
    if (obj("alg")? as String) != "HS256" then error end
    let message: String = parts(0)? + "." + parts(1)?
    if not ConstantTimeCompare(signature, HmacSha256(secret, message)?) then
      error
    end
    let claims = JSONParser.parse(String.from_array(payload)) as JSONObject
    if (claims("exp")? as I64) <= now then error end
    let sub = claims("sub")? as String
    let id = Input.integer(sub)?
    if id <= 0 then error end
    id

  fun _decode(part: String): Array[U8] val ? =>
    if part.size() == 0 then error end
    for ch in part.values() do
      if not (((ch >= 'a') and (ch <= 'z')) or
        ((ch >= 'A') and (ch <= 'Z')) or
        ((ch >= '0') and (ch <= '9')) or (ch == '-') or (ch == '_'))
      then
        error
      end
    end
    let bytes: Array[U8] val = Base64.decode_url(part)?
    let canonical: String = Base64.encode_url(bytes)
    if canonical != part then error end
    bytes
