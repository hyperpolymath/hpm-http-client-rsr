<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# hpm-http-client-rsr ABI/FFI Documentation

## Overview

This library follows the **Hyperpolymath RSR Standard** for ABI and FFI design:

- **ABI (Application Binary Interface)** defined in **Idris2**
- **FFI (Foreign Function Interface)** implemented in **Zig**
- **Generated C headers** bridge Idris2 ABI to Zig FFI
- **Any language** can call through standard C ABI

## Architecture

```
┌─────────────────────────────────────────────┐
│  ABI Definitions (Idris2)                   │
│  src/abi/                                   │
│  - Types.idr     (Type definitions)         │
│  - Foreign.idr   (FFI declarations)         │
└─────────────────┬───────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────┐
│  C Headers                                  │
│  generated/abi/hpm_http_client.h            │
└─────────────────┬───────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────┐
│  FFI Implementation (Zig)                   │
│  ffi/zig/src/main.zig                       │
│  - Wraps std.http.Client                    │
│  - HTTPS via std.crypto.tls.Client          │
└─────────────────┬───────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────┐
│  Any Language via C ABI                     │
└─────────────────────────────────────────────┘
```

## C ABI surface

```c
// Client lifecycle
hpm_http_client_t* hpm_http_client_new(void);
void               hpm_http_client_free(hpm_http_client_t* client);

// One-shot request. method_ordinal matches std.http.Method
// (GET=0 HEAD=1 POST=2 PUT=3 DELETE=4 CONNECT=5 OPTIONS=6 TRACE=7 PATCH=8;
// pass -1 for auto-select: GET if body is empty, POST otherwise).
// extra_headers is in "Name:Value\r\nName:Value\r\n" format.
// Returns a response handle, or NULL on error (URL parse / connect / TLS / IO).
hpm_http_response_t* hpm_http_client_request(
    hpm_http_client_t* client,
    int   method_ordinal,
    const uint8_t* url,           size_t url_len,
    const uint8_t* extra_headers, size_t extra_headers_len,
    const uint8_t* body,          size_t body_len);

// Response inspection
int     hpm_http_response_status(hpm_http_response_t* resp);   // status code, -1 on null
ssize_t hpm_http_response_body(hpm_http_response_t* resp,
                                uint8_t* out, size_t cap);     // bytes written / size-query / -1
void    hpm_http_response_free(hpm_http_response_t* resp);
```

## Methods

| Ordinal | Method |
|---------|--------|
| 0 | GET |
| 1 | HEAD |
| 2 | POST |
| 3 | PUT |
| 4 | DELETE |
| 5 | CONNECT |
| 6 | OPTIONS |
| 7 | TRACE |
| 8 | PATCH |

## Limits

- Response body: 1 MiB per request (configurable in a later version)
- Extra request headers: 16 entries per request
- TLS: handled transparently by `std.crypto.tls.Client` (no caller config)
