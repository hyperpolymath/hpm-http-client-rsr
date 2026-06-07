-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
||| hpm-http-client-rsr — %foreign declarations binding into
||| libhpm_http_client.so.
|||
||| Each external Zig export gets a private `prim__*` `%foreign`
||| declaration plus a safe Idris2 wrapper that converts the raw C
||| return into a typed outcome from `HpmHttpClient.ABI.Types`.

module HpmHttpClient.ABI.Foreign

import Data.Buffer
import HpmHttpClient.ABI.Types

%default total

--------------------------------------------------------------------------------
-- Client lifecycle
--------------------------------------------------------------------------------

||| Raw C call.
|||
|||   hpm_http_client_t* hpm_http_client_new(void);
%foreign "C:hpm_http_client_new, libhpm_http_client"
prim__clientNew : PrimIO AnyPtr

export
clientNew : IO AnyPtr
clientNew = primIO prim__clientNew

%foreign "C:hpm_http_client_free, libhpm_http_client"
prim__clientFree : AnyPtr -> PrimIO ()

export
clientFree : AnyPtr -> IO ()
clientFree c = primIO $ prim__clientFree c

--------------------------------------------------------------------------------
-- One-shot request
--------------------------------------------------------------------------------

||| Raw C call.
|||
|||   hpm_http_response_t* hpm_http_client_request(
|||       hpm_http_client_t* client,
|||       int method_ordinal,
|||       const uint8_t* url,           size_t url_len,
|||       const uint8_t* extra_headers, size_t extra_headers_len,
|||       const uint8_t* body,          size_t body_len);
%foreign "C:hpm_http_client_request, libhpm_http_client"
prim__clientRequest :
     AnyPtr
  -> Int            -- method ordinal (-1 = auto)
  -> Buffer -> Int  -- url
  -> Buffer -> Int  -- extra headers
  -> Buffer -> Int  -- body
  -> PrimIO AnyPtr

||| Issue a one-shot HTTP request. Returns a response handle. NULL on
||| URL-parse / connect / TLS / IO failure.
export
clientRequest :
     (client : AnyPtr)
  -> (method : HttpMethod)
  -> (url : Buffer)          -> (urlLen : Int)
  -> (extraHeaders : Buffer) -> (extraHeadersLen : Int)
  -> (body : Buffer)         -> (bodyLen : Int)
  -> IO AnyPtr
clientRequest client method url urlLen hdrs hdrsLen body bodyLen =
  primIO $ prim__clientRequest client (methodToInt method)
    url urlLen hdrs hdrsLen body bodyLen

--------------------------------------------------------------------------------
-- Response inspection
--------------------------------------------------------------------------------

||| Raw C call.
|||
|||   int hpm_http_response_status(hpm_http_response_t* resp);
|||
||| Returns the HTTP status code, or -1 on NULL.
%foreign "C:hpm_http_response_status, libhpm_http_client"
prim__responseStatus : AnyPtr -> PrimIO Int

export
responseStatus : AnyPtr -> IO Int
responseStatus r = primIO $ prim__responseStatus r

||| Raw C call.
|||
|||   ssize_t hpm_http_response_body(
|||       hpm_http_response_t* resp, uint8_t* out, size_t cap);
|||
||| Returns bytes written, or the required size when `cap == 0` (size
||| query), or -1 on `cap < required` / NULL.
%foreign "C:hpm_http_response_body, libhpm_http_client"
prim__responseBody : AnyPtr -> Buffer -> Int -> PrimIO Int

export
responseBody : (resp : AnyPtr) -> (out : Buffer) -> (cap : Int) -> IO BodyResult
responseBody resp out cap = do
  rc <- primIO $ prim__responseBody resp out cap
  pure (bodyResultFromInt rc)

%foreign "C:hpm_http_response_free, libhpm_http_client"
prim__responseFree : AnyPtr -> PrimIO ()

export
responseFree : AnyPtr -> IO ()
responseFree r = primIO $ prim__responseFree r
