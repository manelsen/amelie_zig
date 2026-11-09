const std = @import("std");

/// Result of a completed HTTP fetch. `body` is heap-allocated; the caller must free it.
pub const FetchResult = struct {
    status: std.http.Status,
    body: []u8,
};

/// Union of fetch errors: wraps `std.http.Client.FetchError` plus `UrlInvalida`.
pub const FetchError = std.http.Client.FetchError || error{
    UrlInvalida,
};

/// Performs an HTTP request and returns the response status and body.
///
/// Creates and destroys a `std.http.Client` per call. The returned `body`
/// is owned by the caller and must be freed with the same `allocator`.
pub fn fetch(
    allocator: std.mem.Allocator,
    location: std.http.Client.FetchOptions.Location,
    options: struct {
        method: ?std.http.Method = null,
        payload: ?[]const u8 = null,
        headers: std.http.Client.Request.Headers = .{},
        extra_headers: []const std.http.Header = &.{},
        privileged_headers: []const std.http.Header = &.{},
    },
) FetchError!FetchResult {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var body_writer = std.Io.Writer.Allocating.init(allocator);
    errdefer body_writer.deinit();

    const result = try client.fetch(.{
        .location = location,
        .method = options.method,
        .payload = options.payload,
        .headers = options.headers,
        .extra_headers = options.extra_headers,
        .privileged_headers = options.privileged_headers,
        .response_writer = &body_writer.writer,
    });

    return .{
        .status = result.status,
        .body = try body_writer.toOwnedSlice(),
    };
}

const testing = std.testing;

const TestServer = struct {
    listener: std.net.Server,
    thread: std.Thread,
    port: u16,

    fn start() !TestServer {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        const listener = try addr.listen(.{ .reuse_address = true });
        const port = listener.listen_address.in.getPort();
        const thread = try std.Thread.spawn(.{}, run, .{listener});
        return .{ .listener = listener, .thread = thread, .port = port };
    }

    fn deinit(self: *TestServer) void {
        self.thread.join();
        self.listener.deinit();
    }

    fn run(listener_arg: std.net.Server) void {
        var listener = listener_arg;
        var conn = listener.accept() catch return;
        defer conn.stream.close();

        var buf: [1024]u8 = undefined;
        _ = conn.stream.read(&buf) catch return;

        const body = "fetch-ok";
        const response = std.fmt.bufPrint(
            &buf,
            "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ body.len, body },
        ) catch return;
        conn.stream.writeAll(response) catch return;
    }
};

test "http_fetch: coleta body com Client.fetch" {
    var server = try TestServer.start();
    defer server.deinit();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/ok", .{server.port});
    defer testing.allocator.free(url);

    const result = try fetch(testing.allocator, .{ .url = url }, .{});
    defer testing.allocator.free(result.body);

    try testing.expectEqual(std.http.Status.ok, result.status);
    try testing.expectEqualStrings("fetch-ok", result.body);
}
