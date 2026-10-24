// ziggy: the zlive demo app.
//
// This file is plumbing: it names the app context, declares which pages and
// assets it serves, and hands the framework a connection handler. The
// transport is zlive's (`zlive.http.Server`), the views are the view
// modules, and nothing here imports httpz.

const std = @import("std");
const zlive = @import("zlive");
const zlive_components = @import("zlive_components");

const handler = @import("handler");
const pages = @import("pages");
const chart_view = @import("chart");

const log = std.log.scoped(.ziggy);

pub const std_options: std.Options = .{
    .logFn = logWithTimestamp,
};

/// std.log sink: "2026-10-09 14:32:07 INFO  ziggy: message" — timestamps
/// on every line (UTC; httpz's workers and our threads share it), one
/// locked write per line so concurrent workers do not interleave.
fn logWithTimestamp(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var line_buf: [2048]u8 = undefined;
    const ts = std.Io.Clock.now(.real, std.Io.Threaded.global_single_threaded.io()).toSeconds();
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(ts, 0)) };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const secs = es.getDaySeconds();
    const line = std.fmt.bufPrint(&line_buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s: <5} {s}: " ++ format, .{
        year_day.year,
        @as(u8, @backingInt(month_day.month)),
        @as(u8, month_day.day_index) + 1,
        secs.getHoursIntoDay(),
        secs.getMinutesIntoHour(),
        secs.getSecondsIntoMinute(),
        @tagName(level),
        @tagName(scope),
    } ++ args) catch return;
    var err_buf: [256]u8 = undefined;
    const w = std.debug.lockStderr(&err_buf);
    w.file_writer.interface.writeAll(line) catch {};
    w.file_writer.interface.writeAll("\n") catch {};
    w.file_writer.interface.flush() catch {};
    std.debug.unlockStderr();
}

/// Application-specific state shared by all requests/connections.
///
/// The framework requires `allocator` and `lock`/`unlock`: the app lock
/// serializes renders against the notification reapers and against the
/// scoped store's cross-session notifications. `registry` parks a
/// disconnected view's state for rejoin.
pub const App = struct {
    /// The connection handler the framework upgrades `/ws` to.
    pub const WebsocketHandler = handler.Handler;

    allocator: std.mem.Allocator,
    /// The event loop the transport listens on (httpz requires it on the
    /// context type).
    io: std.Io,
    /// The app lock. **Recursive**, on purpose: the scoped store holds it
    /// while flushing every member of a group, and a notification reaper
    /// holds it while calling this session's `flush`. Both of those call
    /// `pushUpdate`, which locks. A non-recursive lock would deadlock there
    /// (the other option is a `flushLocked` that assumes the lock — see
    /// zlive's scope.zig and notify.zig).
    mutex: std.atomic.Mutex = .unlocked,
    lock_depth: usize = 0,
    lock_owner: ?std.Thread.Id = null,
    /// Session token -> state of a view whose connection went away.
    registry: Registry,
    /// Scoped state: global + per-group cells, and group membership.
    store: Store,

    pub const Registry = zlive.Registry(Stashed);
    pub const Store = zlive.http.Store(App, 8);

    /// What a parked session carries. The framework stores it opaquely.
    pub const Stashed = struct { count: i64 };

    /// How long a disconnected view's state is kept for rejoin, in seconds.
    pub const ttl_sec: i64 = 5 * 60;

    /// How long an empty group's state is kept, in seconds.
    pub const group_ttl_sec: i64 = 5 * 60;

    /// Builds the app *in place*: `App` owns a registry (mutex + hash map)
    /// and must never be copied after construction, so callers pass the
    /// storage they want filled rather than assigning a returned value.
    pub fn init(self: *App, allocator: std.mem.Allocator, io: std.Io) void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .registry = Registry.init(allocator, now, ttl_sec),
            .store = Store.init(self, allocator, now, group_ttl_sec),
        };
    }

    fn now() i64 {
        return std.Io.Clock.now(.real, std.Io.Threaded.global_single_threaded.io()).toSeconds();
    }

    /// The notification queues' clock (milliseconds): a toast's deadline is
    /// set from this, so a queue only ever compares two readings of it.
    /// Callable from the reaper's own thread.
    pub fn nowMs() i64 {
        return std.Io.Clock.now(.real, std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
    }

    /// Recursive: the owner may re-enter. The owner field is only written
    /// by the holder and only read for the fast path, so the worst a torn
    /// read can do is take the slow path.
    pub fn lock(self: *App) void {
        const me = std.Thread.getCurrentId();
        if (self.lock_owner) |owner| {
            if (owner == me) {
                self.lock_depth += 1;
                return;
            }
        }
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        self.lock_owner = me;
        self.lock_depth = 1;
    }

    pub fn unlock(self: *App) void {
        if (self.lock_depth > 1) {
            self.lock_depth -= 1;
            return;
        }
        self.lock_depth = 0;
        self.lock_owner = null;
        self.mutex.unlock();
    }

    /// Parks a disconnected view's state on behalf of the handler.
    pub fn stash(self: *App, token: []const u8, value: Stashed) !void {
        return self.registry.stash(token, value);
    }

    /// Claims parked state for `token`, if still within the TTL.
    pub fn restore(self: *App, token: []const u8) ?Stashed {
        return self.registry.restore(token);
    }

    /// Session-token validation, run before the WebSocket upgrade.
    ///
    /// TODO: verify a real token. Returning false rejects `/ws` with 401
    /// and the connection is never upgraded.
    pub fn authorizeSocket(self: *App, req: *zlive.http.Request) bool {
        _ = self;
        _ = req.header("x-session-token") orelse "";
        return true;
    }

    /// Runs while the transport's handler storage is still alive: the
    /// registry's keys were allocated with this allocator, so it must be
    /// released before the app's own storage goes away. Tracking exits
    /// here (the allocator's leak check then sees a clean shutdown).
    pub fn shutdown(self: *App) void {
        // The notification reapers are detached (a closing connection must
        // never wait on one), so a reaper can still be asleep holding a
        // queue's state when the process is ready to exit. Let it notice the
        // disarm first, or its state is reported as leaked. The chart view's
        // tickers follow the same pattern and get the same wait.
        _ = zlive.http.notify.waitIdle(1000);
        _ = chart_view.waitIdle(1000);
        self.registry.deinit();
        // Group cells, the global scope and the session list are all
        // allocated with this allocator.
        self.store.deinit();
    }

    /// Run by the framework after the transport has been torn down. The
    /// registry is already gone (see `shutdown`), so there is nothing left
    /// to release here.
    pub fn deinit(self: *App) void {
        _ = self;
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = undefined;
    app.init(init.gpa, init.io);

    // Every page is embedded (rendered from its layout at build time, see
    // src/pages.zig), so the binary serves everything it needs: no static
    // directory, no working-directory requirement, no per-request file I/O.
    // `App.shutdown`/`App.deinit` run from the framework's Server.deinit,
    // after the listener stops and no connection can still touch app state.
    const config: zlive.http.Server(App).Config = .{
        .pages = &page_routes,
    };
    var server = try zlive.http.Server(App).init(config, &app);
    defer server.deinit();

    // The framework's own client runtime and the component library's hooks
    // and stylesheet are embedded in those packages.
    try server.asset(config, "/client.js", zlive.client_js, zlive.http.static.ContentType.js);
    try server.asset(config, "/hooks.js", zlive_components.hooks_js, zlive.http.static.ContentType.js);
    try server.asset(config, "/zc.css", zlive_components.css, zlive.http.static.ContentType.css);
    try server.asset(config, "/theme.js", pages.theme_js, zlive.http.static.ContentType.js);

    try server.socket(config, "/ws");

    try server.run();
}

/// The embedded pages in the framework's config shape. The route is the
/// page's `path`; `file` only names the content type.
const page_routes = blk: {
    var list: [pages.all.len]zlive.http.Server(App).Page = undefined;
    for (pages.all, 0..) |page, i| {
        list[i] = .{ .path = page.path, .file = page.file, .bytes = page.bytes };
    }
    break :blk list;
};

/// Test helper: fills `app` in place and tightens the registry TTL, which
/// is read through a function pointer fixed at construction.
fn testApp(app: *App, ttl_sec: i64) void {
    app.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.io());
    app.registry.ttl_sec = ttl_sec;
}

test "registry round trip consumes the entry" {
    var app: App = undefined;
    testApp(&app, 5 * 60);
    defer app.shutdown();

    try app.stash("tok", .{ .count = 7 });
    try std.testing.expectEqual(@as(i64, 7), app.restore("tok").?.count);
    try std.testing.expect(app.restore("tok") == null);
}

test "registry entry expires after the ttl" {
    var app: App = undefined;
    testApp(&app, -1); // anything parked is already stale
    defer app.shutdown();

    try app.stash("tok", .{ .count = 1 });
    try std.testing.expect(app.restore("tok") == null);
}

test "restashing the same token replaces the entry" {
    var app: App = undefined;
    testApp(&app, 5 * 60);
    defer app.shutdown();

    try app.stash("tok", .{ .count = 1 });
    try app.stash("tok", .{ .count = 2 });
    try std.testing.expectEqual(@as(i64, 2), app.restore("tok").?.count);
}
