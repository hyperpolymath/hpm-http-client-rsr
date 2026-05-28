// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// hpm-http-client-rsr — one-shot HTTPS client primitives.
//
// Built on `std.http.Client`, which gives us HTTPS via
// `std.crypto.tls.Client` for free. The FFI surface is intentionally
// minimal: one client object, one request call, one response handle to
// inspect status + body.

const std = @import("std");
const http = std.http;
const net = std.net;

const MAX_RESPONSE_BODY_BYTES: usize = 1 * 1024 * 1024;
const MAX_EXTRA_HEADERS: usize = 16;

/// Handle returned by `hpm_http_client_new`. Owns an `std.http.Client`
/// instance plus the allocator backing it.
pub const HpmHttpClient = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
};

/// Handle returned by `hpm_http_client_request`. Owns a copy of the
/// response body sized to its actual length.
pub const HpmHttpResponse = struct {
    allocator: std.mem.Allocator,
    status: u16,
    body: []u8,
};

/// Create a new client. Returns NULL on allocator failure.
export fn hpm_http_client_new() ?*HpmHttpClient {
    const allocator = std.heap.c_allocator;
    const ctx = allocator.create(HpmHttpClient) catch return null;
    ctx.* = .{
        .allocator = allocator,
        .client = .{ .allocator = allocator },
    };
    return ctx;
}

/// Free the client and any resources it holds.
export fn hpm_http_client_free(client: ?*HpmHttpClient) void {
    const c = client orelse return;
    c.client.deinit();
    c.allocator.destroy(c);
}

/// One-shot HTTP/S request.
///
/// `method_ordinal` matches `std.http.Method` ordinals:
/// 0=GET 1=HEAD 2=POST 3=PUT 4=DELETE 5=CONNECT 6=OPTIONS 7=TRACE 8=PATCH.
/// Pass -1 for auto: GET if body is empty, POST otherwise.
///
/// `extra_headers` is a `"Name:Value\r\nName:Value\r\n"` buffer (max
/// 16 entries).
///
/// Returns a response handle, or NULL on URL parse / connect / TLS / IO
/// error. Free the handle with `hpm_http_response_free`.
export fn hpm_http_client_request(
    client_ptr: ?*HpmHttpClient,
    method_ordinal: c_int,
    url_ptr: ?[*]const u8,
    url_len: usize,
    extra_headers_ptr: ?[*]const u8,
    extra_headers_len: usize,
    body_ptr: ?[*]const u8,
    body_len: usize,
) ?*HpmHttpResponse {
    const c = client_ptr orelse return null;
    const up = url_ptr orelse return null;
    if (url_len == 0) return null;
    const url = up[0..url_len];

    const method: ?http.Method = blk: {
        if (method_ordinal == -1) break :blk null;
        if (method_ordinal < 0 or method_ordinal > 8) return null;
        const tag: @typeInfo(http.Method).@"enum".tag_type = @intCast(method_ordinal);
        break :blk @enumFromInt(tag);
    };

    var extra: [MAX_EXTRA_HEADERS]http.Header = undefined;
    var n_extra: usize = 0;
    if (extra_headers_ptr) |hp| {
        if (extra_headers_len > 0) {
            const hdrs = hp[0..extra_headers_len];
            var lines = std.mem.splitSequence(u8, hdrs, "\r\n");
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                if (colon == 0) continue;
                if (n_extra >= extra.len) return null;
                extra[n_extra] = .{
                    .name = line[0..colon],
                    .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
                };
                n_extra += 1;
            }
        }
    }

    const body: ?[]const u8 = if (body_ptr) |bp| (if (body_len > 0) bp[0..body_len] else null) else null;

    var body_writer = std.Io.Writer.Allocating.init(c.allocator);
    defer body_writer.deinit();

    const result = c.client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .extra_headers = extra[0..n_extra],
        .response_writer = &body_writer.writer,
    }) catch return null;

    if (body_writer.writer.end > MAX_RESPONSE_BODY_BYTES) return null;

    const owned = body_writer.toOwnedSlice() catch return null;

    const resp = c.allocator.create(HpmHttpResponse) catch {
        c.allocator.free(owned);
        return null;
    };
    resp.* = .{
        .allocator = c.allocator,
        .status = @intFromEnum(result.status),
        .body = owned,
    };
    return resp;
}

/// HTTP status code. -1 on NULL.
export fn hpm_http_response_status(resp: ?*HpmHttpResponse) c_int {
    const r = resp orelse return -1;
    return @intCast(r.status);
}

/// Copy the body into `out`. Returns bytes written, or the required
/// size when `out` is NULL or `cap` is 0 (size-query), or -1 on
/// `cap < required` or NULL response.
export fn hpm_http_response_body(
    resp: ?*HpmHttpResponse,
    out: ?[*]u8,
    cap: usize,
) isize {
    const r = resp orelse return -1;
    if (out == null or cap == 0) return @intCast(r.body.len);
    if (cap < r.body.len) return -1;
    @memcpy(out.?[0..r.body.len], r.body);
    return @intCast(r.body.len);
}

/// Free a response handle.
export fn hpm_http_response_free(resp: ?*HpmHttpResponse) void {
    const r = resp orelse return;
    r.allocator.free(r.body);
    r.allocator.destroy(r);
}

//==============================================================================
// Tests
//==============================================================================
//
// We spawn an in-process HTTP server on the loopback interface, then
// fire client requests at it. Tests use plain HTTP (no TLS) because
// driving a self-signed TLS endpoint inside the test harness is more
// complexity than it earns. HTTPS is exercised by the OikosBot itself
// against api.github.com once that consumer lands.

const TestServerCtx = struct {
    address: net.Address,
    expected_path: []const u8 = "/",
    expected_method: http.Method = .GET,
    expected_body: []const u8 = "",
    reply_status: http.Status = .ok,
    reply_body: []const u8 = "ok",
    reply_headers: []const http.Header = &.{},
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn testServerThread(ctx: *TestServerCtx) void {
    var listener = ctx.address.listen(.{ .reuse_address = true }) catch return;
    defer listener.deinit();
    ctx.address = listener.listen_address;
    ctx.ready.store(true, .release);

    const conn = listener.accept() catch return;
    defer conn.stream.close();

    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var conn_reader = conn.stream.reader(&recv_buf);
    var conn_writer = conn.stream.writer(&send_buf);
    var server = http.Server.init(conn_reader.interface(), &conn_writer.interface);

    var request = server.receiveHead() catch return;
    if (request.head.method != ctx.expected_method) return;
    if (!std.mem.eql(u8, request.head.target, ctx.expected_path)) return;

    if (request.head.method.requestHasBody() and ctx.expected_body.len > 0) {
        var scratch: [4096]u8 = undefined;
        const reader = request.readerExpectNone(&scratch);
        var actual: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < ctx.expected_body.len) {
            const n = reader.readSliceShort(actual[total..ctx.expected_body.len]) catch return;
            if (n == 0) break;
            total += n;
        }
        if (!std.mem.eql(u8, actual[0..total], ctx.expected_body)) return;
    }

    request.respond(ctx.reply_body, .{
        .status = ctx.reply_status,
        .extra_headers = ctx.reply_headers,
        .keep_alive = false,
    }) catch return;
}

fn waitReady(ctx: *TestServerCtx) void {
    while (!ctx.ready.load(.acquire)) std.Thread.yield() catch {};
}

fn formatUrl(buf: []u8, port: u16, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ port, path });
}

test "client new + free" {
    const c = hpm_http_client_new() orelse return error.NewFailed;
    hpm_http_client_free(c);
}

test "client free null is safe" {
    hpm_http_client_free(null);
}

test "request with null url returns null" {
    const c = hpm_http_client_new() orelse return error.NewFailed;
    defer hpm_http_client_free(c);
    const r = hpm_http_client_request(c, -1, null, 0, null, 0, null, 0);
    try std.testing.expect(r == null);
}

test "request with malformed url returns null" {
    const c = hpm_http_client_new() orelse return error.NewFailed;
    defer hpm_http_client_free(c);
    const url = "not-a-url";
    const r = hpm_http_client_request(c, -1, url.ptr, url.len, null, 0, null, 0);
    try std.testing.expect(r == null);
}

test "GET round trip" {
    const c = hpm_http_client_new() orelse return error.NewFailed;
    defer hpm_http_client_free(c);

    var ctx: TestServerCtx = .{
        .address = try net.Address.parseIp("127.0.0.1", 0),
        .expected_path = "/hello",
        .expected_method = .GET,
        .reply_body = "world",
    };
    const t = try std.Thread.spawn(.{}, testServerThread, .{&ctx});
    waitReady(&ctx);

    var url_buf: [128]u8 = undefined;
    const url = try formatUrl(&url_buf, ctx.address.getPort(), "/hello");

    const resp = hpm_http_client_request(c, 0, url.ptr, url.len, null, 0, null, 0) orelse {
        t.join();
        return error.RequestFailed;
    };
    defer hpm_http_response_free(resp);
    t.join();

    try std.testing.expectEqual(@as(c_int, 200), hpm_http_response_status(resp));

    var body_buf: [64]u8 = undefined;
    const n = hpm_http_response_body(resp, &body_buf, body_buf.len);
    try std.testing.expectEqual(@as(isize, 5), n);
    try std.testing.expectEqualStrings("world", body_buf[0..@intCast(n)]);
}

test "POST round trip with body" {
    const c = hpm_http_client_new() orelse return error.NewFailed;
    defer hpm_http_client_free(c);

    var ctx: TestServerCtx = .{
        .address = try net.Address.parseIp("127.0.0.1", 0),
        .expected_path = "/webhook",
        .expected_method = .POST,
        .expected_body = "hello world",
        .reply_body = "received",
    };
    const t = try std.Thread.spawn(.{}, testServerThread, .{&ctx});
    waitReady(&ctx);

    var url_buf: [128]u8 = undefined;
    const url = try formatUrl(&url_buf, ctx.address.getPort(), "/webhook");
    const body = "hello world";

    const resp = hpm_http_client_request(c, 2, url.ptr, url.len, null, 0, body.ptr, body.len) orelse {
        t.join();
        return error.RequestFailed;
    };
    defer hpm_http_response_free(resp);
    t.join();

    try std.testing.expectEqual(@as(c_int, 200), hpm_http_response_status(resp));

    var body_buf: [64]u8 = undefined;
    const n = hpm_http_response_body(resp, &body_buf, body_buf.len);
    try std.testing.expectEqualStrings("received", body_buf[0..@intCast(n)]);
}

test "extra request headers" {
    const c = hpm_http_client_new() orelse return error.NewFailed;
    defer hpm_http_client_free(c);

    var ctx: TestServerCtx = .{
        .address = try net.Address.parseIp("127.0.0.1", 0),
        .expected_path = "/h",
        .expected_method = .GET,
        .reply_body = "ok",
    };
    const t = try std.Thread.spawn(.{}, testServerThread, .{&ctx});
    waitReady(&ctx);

    var url_buf: [128]u8 = undefined;
    const url = try formatUrl(&url_buf, ctx.address.getPort(), "/h");
    const hdrs = "x-bot-token:abc123\r\nuser-agent:hpm-bot/0.1";

    const resp = hpm_http_client_request(c, 0, url.ptr, url.len, hdrs.ptr, hdrs.len, null, 0) orelse {
        t.join();
        return error.RequestFailed;
    };
    defer hpm_http_response_free(resp);
    t.join();

    try std.testing.expectEqual(@as(c_int, 200), hpm_http_response_status(resp));
}

test "404 status propagates" {
    const c = hpm_http_client_new() orelse return error.NewFailed;
    defer hpm_http_client_free(c);

    var ctx: TestServerCtx = .{
        .address = try net.Address.parseIp("127.0.0.1", 0),
        .expected_path = "/missing",
        .expected_method = .GET,
        .reply_status = .not_found,
        .reply_body = "missing",
    };
    const t = try std.Thread.spawn(.{}, testServerThread, .{&ctx});
    waitReady(&ctx);

    var url_buf: [128]u8 = undefined;
    const url = try formatUrl(&url_buf, ctx.address.getPort(), "/missing");
    const resp = hpm_http_client_request(c, 0, url.ptr, url.len, null, 0, null, 0) orelse {
        t.join();
        return error.RequestFailed;
    };
    defer hpm_http_response_free(resp);
    t.join();

    try std.testing.expectEqual(@as(c_int, 404), hpm_http_response_status(resp));
}

test "body size-query" {
    const c = hpm_http_client_new() orelse return error.NewFailed;
    defer hpm_http_client_free(c);

    var ctx: TestServerCtx = .{
        .address = try net.Address.parseIp("127.0.0.1", 0),
        .expected_path = "/sz",
        .reply_body = "twelve bytes",
    };
    const t = try std.Thread.spawn(.{}, testServerThread, .{&ctx});
    waitReady(&ctx);

    var url_buf: [128]u8 = undefined;
    const url = try formatUrl(&url_buf, ctx.address.getPort(), "/sz");
    const resp = hpm_http_client_request(c, 0, url.ptr, url.len, null, 0, null, 0) orelse {
        t.join();
        return error.RequestFailed;
    };
    defer hpm_http_response_free(resp);
    t.join();

    try std.testing.expectEqual(@as(isize, 12), hpm_http_response_body(resp, null, 0));

    var small_buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(isize, -1), hpm_http_response_body(resp, &small_buf, small_buf.len));
}

test "auto method selects GET with no body, POST with body" {
    const c = hpm_http_client_new() orelse return error.NewFailed;
    defer hpm_http_client_free(c);

    // No body → GET
    {
        var ctx: TestServerCtx = .{
            .address = try net.Address.parseIp("127.0.0.1", 0),
            .expected_path = "/a",
            .expected_method = .GET,
            .reply_body = "g",
        };
        const t = try std.Thread.spawn(.{}, testServerThread, .{&ctx});
        waitReady(&ctx);

        var url_buf: [128]u8 = undefined;
        const url = try formatUrl(&url_buf, ctx.address.getPort(), "/a");
        const resp = hpm_http_client_request(c, -1, url.ptr, url.len, null, 0, null, 0) orelse {
            t.join();
            return error.RequestFailed;
        };
        defer hpm_http_response_free(resp);
        t.join();
        try std.testing.expectEqual(@as(c_int, 200), hpm_http_response_status(resp));
    }

    // With body → POST
    {
        var ctx: TestServerCtx = .{
            .address = try net.Address.parseIp("127.0.0.1", 0),
            .expected_path = "/b",
            .expected_method = .POST,
            .expected_body = "x",
            .reply_body = "p",
        };
        const t = try std.Thread.spawn(.{}, testServerThread, .{&ctx});
        waitReady(&ctx);

        var url_buf: [128]u8 = undefined;
        const url = try formatUrl(&url_buf, ctx.address.getPort(), "/b");
        const body = "x";
        const resp = hpm_http_client_request(c, -1, url.ptr, url.len, null, 0, body.ptr, body.len) orelse {
            t.join();
            return error.RequestFailed;
        };
        defer hpm_http_response_free(resp);
        t.join();
        try std.testing.expectEqual(@as(c_int, 200), hpm_http_response_status(resp));
    }
}

test "null response accessors return -1 / no-op" {
    try std.testing.expectEqual(@as(c_int, -1), hpm_http_response_status(null));
    try std.testing.expectEqual(@as(isize, -1), hpm_http_response_body(null, null, 0));
    hpm_http_response_free(null);
}

test "method ordinals match std.http.Method" {
    try std.testing.expectEqual(@as(c_int, 0), @as(c_int, @intCast(@intFromEnum(http.Method.GET))));
    try std.testing.expectEqual(@as(c_int, 2), @as(c_int, @intCast(@intFromEnum(http.Method.POST))));
    try std.testing.expectEqual(@as(c_int, 4), @as(c_int, @intCast(@intFromEnum(http.Method.DELETE))));
    try std.testing.expectEqual(@as(c_int, 8), @as(c_int, @intCast(@intFromEnum(http.Method.PATCH))));
}

test "invalid method ordinal returns null" {
    const c = hpm_http_client_new() orelse return error.NewFailed;
    defer hpm_http_client_free(c);
    const url = "http://127.0.0.1:1/";
    const r = hpm_http_client_request(c, 99, url.ptr, url.len, null, 0, null, 0);
    try std.testing.expect(r == null);
}
