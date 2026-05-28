||| hpm-http-client-rsr — type declarations for the FFI boundary.
|||
||| Mirrors the design of hpm-crypto-rsr: every type that crosses the
||| C ABI is declared here so the Idris2 wrappers in `Foreign.idr` have
||| a single source of truth and the C header generator can emit
||| matching `typedef`s.

module HpmHttpClient.ABI.Types

import Data.Buffer

%default total

--------------------------------------------------------------------------------
-- HTTP method ordinals (match std.http.Method in Zig)
--------------------------------------------------------------------------------

public export
data HttpMethod
  = MGet
  | MHead
  | MPost
  | MPut
  | MDelete
  | MConnect
  | MOptions
  | MTrace
  | MPatch
  | MAuto      -- Encoded as -1: let the FFI pick GET / POST based on body.

export
methodToInt : HttpMethod -> Int
methodToInt MGet     = 0
methodToInt MHead    = 1
methodToInt MPost    = 2
methodToInt MPut     = 3
methodToInt MDelete  = 4
methodToInt MConnect = 5
methodToInt MOptions = 6
methodToInt MTrace   = 7
methodToInt MPatch   = 8
methodToInt MAuto    = -1

--------------------------------------------------------------------------------
-- Status / body outcomes from the C ABI
--------------------------------------------------------------------------------

||| Outcome of `hpm_http_response_body`. The Zig side returns:
|||   ≥ 0  = bytes written (or required size if `out_cap == 0`)
|||   -1   = error / output buffer too small
public export
data BodyResult : Type where
  BodyOk : (bytesWritten : Nat) -> BodyResult
  BodyError : BodyResult

export
bodyResultFromInt : Int -> BodyResult
bodyResultFromInt n =
  if n < 0
    then BodyError
    else BodyOk (cast n)

--------------------------------------------------------------------------------
-- Size constants
--------------------------------------------------------------------------------

||| Maximum response body size accepted by the FFI. Larger responses
||| return `BodyError`. Documented for callers sizing their out buffer.
public export
MaxResponseBodyBytes : Nat
MaxResponseBodyBytes = 1024 * 1024
