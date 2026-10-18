// The app's connection handler: one WebSocket session.
//
// Everything transport-shaped lives in the framework (`zlive.http.Service`:
// envelope decode, the message-size cap, error replies, session token) and
// every view's state lives in the framework's slot registry. What is left
// here is the app's own policy: which topics exist, and the small set of
// helpers that cross views.

const std = @import("std");
const zlive = @import("zlive");

const protocol = zlive.protocol;
const util = zlive.util;
const Service = zlive.http.Service;
const Slots = zlive.http.Slots;

const App = @import("main").App;

const counter_view = @import("counter");
const table_view = @import("table_demo");
const form_view = @import("form_demo");
const tabs_view = @import("tabs");
const countries_view = @import("countries");
const kitchen_view = @import("kitchen_sink");
const room_view = @import("room");
const sidebar_view = @import("sidebar");
const themes_view = @import("themes");
const notify = @import("notify");
const view = @import("view");

const log = std.log.scoped(.ziggy);

/// The app's notification queues, named here so views and the handler refer
/// to them without repeating the parameters (see src/notify.zig).
pub const BannerQueue = notify.Banner;
pub const ToastQueue = notify.Toast;

pub const Handler = struct {
    /// Transport: connection, app, session token, reply helpers.
    service: Service(App),
    /// The connection's view states, one slot each, created on mount and
    /// torn down on close.
    slots: Slots(8),

    // Slot keys. A connection typically mounts one view, so the states
    // below are addressed by name rather than by field.
    const counter_key = "counter";
    const table_key = "table";
    const form_key = "form";
    const tabs_key = "tabs";
    const countries_key = "countries";
    const kitchen_key = "kitchen";
    const room_key = "room";
    const sidebar_key = "sidebar";
    const themes_key = "themes";
    const banner_key = "banner";
    const toast_key = "toast";

    // The transport's connection-handler shape: the handshake is validated
    // in the framework's `/ws` action, so init receives the connection and
    // the app pointer the upgrade was given.
    pub fn init(conn: *zlive.http.Conn, ctx: *App) !Handler {
        return .{
            .service = Service(App).init(conn, ctx),
            .slots = Slots(8).init(ctx.allocator),
        };
    }

    /// What a queue needs to be built completely: the app (its allocator and
    /// lock), this handler (so its reaper can call `flush`) and the clock.
    /// All are per-connection, so the factory takes them through the
    /// registry's runtime-creation path.
    const QueueCtx = struct { app: *App, handler: *Handler };

    fn createBanner(ctx: *anyopaque, _: std.mem.Allocator) BannerQueue {
        const c: *QueueCtx = @ptrCast(@alignCast(ctx));
        return BannerQueue.init(c.app, c.handler, App.nowMs);
    }

    fn createToasts(ctx: *anyopaque, _: std.mem.Allocator) ToastQueue {
        const c: *QueueCtx = @ptrCast(@alignCast(ctx));
        return ToastQueue.init(c.app, c.handler, App.nowMs);
    }

    /// The framework drives a connection through these two entry points.
    /// They stay thin forwarders so `Service` owns the protocol behavior.
    pub fn clientMessage(self: *Handler, aa: std.mem.Allocator, data: []const u8) !void {
        return self.service.clientMessage(self, aa, data);
    }

    pub fn close(self: *Handler) void {
        defer self.service.deinit(); // frees the adopted session token
        // Everything below reads or frees view state, and either the store's
        // notify loop or a queue's reaper can be inside a `flush` that reads
        // the same state — so park the counter and tear the slots down under
        // the app lock. `slots.deinit` is also what disarms the reapers: it
        // clears each queue's `alive` flag, and a reaper only ever touches
        // this handler after seeing that flag while holding this lock.
        self.app().lock();
        defer self.app().unlock();
        self.app().store.detach(self);
        if (self.counter()) |m| {
            if (self.service.token) |t| {
                // Park the view state so a rejoin within the TTL can
                // restore it instead of mounting fresh.
                self.app().stash(t, .{ .count = m.count }) catch |err| {
                    log.err("failed to stash view state: {t}", .{err});
                };
            }
        }
        self.slots.deinit();
        log.info("connection closed", .{});
    }

    // ---------------------------------------------------------------
    // Slots: typed, framework-owned view state
    // ---------------------------------------------------------------

    pub fn get(self: *Handler, comptime key: []const u8, comptime State: type) ?*State {
        return self.slots.get(key, State);
    }

    /// The view's state, creating it via `create` on first use.
    pub fn ensure(
        self: *Handler,
        comptime key: []const u8,
        comptime State: type,
        comptime create: *const fn (std.mem.Allocator) State,
    ) !*State {
        return self.slots.getOrCreate(key, State, create);
    }

    pub fn put(self: *Handler, comptime key: []const u8, comptime State: type, value: State) !*State {
        return self.slots.put(State, key, value);
    }

    /// Named accessors for the demo's views. Every one is a slot lookup:
    /// the registry is the storage, these are the app's ergonomic names.
    pub fn counter(self: *Handler) ?*counter_view.State {
        return self.get(counter_key, counter_view.State);
    }
    pub fn table(self: *Handler) ?*table_view.State {
        return self.get(table_key, table_view.State);
    }
    pub fn form(self: *Handler) ?*form_view.State {
        return self.get(form_key, form_view.State);
    }
    pub fn tabs(self: *Handler) ?*tabs_view.State {
        return self.get(tabs_key, tabs_view.State);
    }
    pub fn countries(self: *Handler) ?*countries_view.State {
        return self.get(countries_key, countries_view.State);
    }
    pub fn room(self: *Handler) ?*room_view.State {
        return self.get(room_key, room_view.State);
    }
    pub fn sidebar(self: *Handler) ?*sidebar_view.State {
        return self.get(sidebar_key, sidebar_view.State);
    }
    pub fn kitchen(self: *Handler) ?*kitchen_view.State {
        return self.get(kitchen_key, kitchen_view.State);
    }
    pub fn themes(self: *Handler) ?*themes_view.State {
        return self.get(themes_key, themes_view.State);
    }

    pub fn app(self: *Handler) *App {
        return self.service.app;
    }

    // ---------------------------------------------------------------
    // Dispatch
    // ---------------------------------------------------------------

    /// Routes a decoded envelope to its view by topic.
    pub fn dispatch(self: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
        if (std.mem.eql(u8, env.topic, room_view.topic)) return room_view.handle(self, aa, env);
        if (std.mem.eql(u8, env.topic, sidebar_view.topic)) return sidebar_view.handle(self, aa, env);
        if (std.mem.eql(u8, env.topic, counter_view.topic)) return counter_view.handle(self, aa, env);
        if (std.mem.eql(u8, env.topic, table_view.topic)) return table_view.handle(self, aa, env);
        if (std.mem.eql(u8, env.topic, form_view.topic)) return form_view.handle(self, aa, env);
        if (std.mem.eql(u8, env.topic, tabs_view.topic)) return tabs_view.handle(self, aa, env);
        if (std.mem.eql(u8, env.topic, countries_view.topic)) return countries_view.handle(self, aa, env);
        if (std.mem.eql(u8, env.topic, kitchen_view.topic)) return kitchen_view.handle(self, aa, env);
        if (std.mem.eql(u8, env.topic, themes_view.topic)) return themes_view.handle(self, aa, env);
        return self.sendErr(aa, env, "unknown_topic");
    }

    // ---------------------------------------------------------------
    // Scoped state: the store's notification target
    // ---------------------------------------------------------------

    /// "Re-render whatever this session is showing and write the patch."
    ///
    /// Two things call it from another thread, both with the app lock
    /// already held: `zlive.http.Store`, when a group or global value this
    /// session renders changed, and a notification queue's reaper, when a
    /// message expired. It must therefore be cheap, must not block on
    /// anything but its own socket, and must tolerate a session that is not
    /// showing the relevant view — every view's `flush` returns immediately
    /// when it is not mounted.
    pub fn flush(self: *Handler) void {
        counter_view.flush(self);
        kitchen_view.flush(self);
        room_view.flush(self);
    }

    // ---------------------------------------------------------------
    // Replies (thin forwarders to the service)
    // ---------------------------------------------------------------

    pub fn send(self: *Handler, aa: std.mem.Allocator, env: protocol.Envelope) !void {
        return self.service.send(aa, env);
    }

    pub fn sendErr(self: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope, reason: []const u8) !void {
        return self.service.sendErr(aa, env, reason);
    }

    pub fn sendParseError(
        self: *Handler,
        aa: std.mem.Allocator,
        data: []const u8,
        event: []const u8,
        reason: []const u8,
    ) !void {
        return self.service.sendParseError(aa, data, event, reason);
    }

    pub fn adoptToken(self: *Handler, token: []const u8) !void {
        return self.service.adoptToken(token);
    }

    // ---------------------------------------------------------------
    // Notifications: the inline banner, and the corner toast stack
    // ---------------------------------------------------------------

    /// The connection's banner queue, created on first use. The queue owns
    /// the messages it is given and its own reaper thread; the view renders
    /// `bannerQueue().?.items()`.
    pub fn bannerQueue(self: *Handler) !*BannerQueue {
        var ctx = QueueCtx{ .app = self.app(), .handler = self };
        return self.slots.getOrCreateWith(banner_key, BannerQueue, &ctx, createBanner);
    }

    /// Shows a banner: queues it and arms its deadline. The caller re-renders
    /// and pushes the update (`pushUpdate`, which takes the lock); the
    /// *expiry* is pushed by the queue's reaper, through `flush`.
    pub fn showBanner(self: *Handler, message: []const u8, level: view.Flash.Level, ttl_ms: u64) !u64 {
        const q = try self.bannerQueue();
        const id = try q.show(.{ .message = message, .level = level }, ttl_ms);
        log.info("banner: \"{s}\" {s} (ttl {d}ms)", .{ message, @tagName(level), ttl_ms });
        return id;
    }

    /// The connection's toast queue, created on first use. Separate from the
    /// banner queue so a toast and an inline banner can be up at once.
    pub fn toastQueue(self: *Handler) !*ToastQueue {
        var ctx = QueueCtx{ .app = self.app(), .handler = self };
        return self.slots.getOrCreateWith(toast_key, ToastQueue, &ctx, createToasts);
    }

    /// Queues a toast in the corner stack, newest nearest the corner.
    pub fn showToast(self: *Handler, message: []const u8, level: view.Toast.Level, ttl_ms: u64) !u64 {
        const q = try self.toastQueue();
        const id = try q.show(.{ .message = message, .level = level }, ttl_ms);
        log.info("toast: \"{s}\" {s} (ttl {d}ms)", .{ message, @tagName(level), ttl_ms });
        return id;
    }

    /// Dismisses one toast now (its close button). The caller re-renders and
    /// diffs, so the stack closes through the ordinary patch path.
    pub fn dismissToast(self: *Handler, id: u64) !bool {
        const q = try self.toastQueue();
        return q.dismiss(id);
    }
};

// Extracts the session token from a join payload: {"session":"<token>"}.
pub fn sessionToken(payload: ?std.json.Value) ?[]const u8 {
    return util.sessionToken(payload);
}
