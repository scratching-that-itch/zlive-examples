const std = @import("std");
const protocol = @import("zlive").protocol;
const view = @import("view");
const util = @import("zlive").util;
const Handler = @import("handler").Handler;

const log = std.log.scoped(.ziggy);

pub const topic = "view:form";

const form_options = [_]view.Select.Option_{
    .{ .value = "user", .label = "User" },
    .{ .value = "admin", .label = "Admin" },
    .{ .value = "owner", .label = "Owner" },
};

pub const State = struct {
    name: [64]u8 = undefined,
    name_len: usize = 0,
    email: [64]u8 = undefined,
    email_len: usize = 0,
    role: usize = 0,
    subscribe: bool = false,
    submitting: bool = false,
    // status line under the form ("Saving…" / "Saved!"); literals only
    status: []const u8 = "",
    // feedback dialog (rendered at view root level — the portal rule)
    dialog_open: bool = false,
    dialog_status: []const u8 = "",
    d_name: [64]u8 = undefined,
    d_name_len: usize = 0,
    d_email: [64]u8 = undefined,
    d_email_len: usize = 0,
    arenas: [2]std.heap.ArenaAllocator,
    trees: [2][]const view.Segment = .{ &.{}, &.{} },
    active: usize = 0,

    fn init(allocator: std.mem.Allocator) State {
        return .{ .arenas = .{
            std.heap.ArenaAllocator.init(allocator),
            std.heap.ArenaAllocator.init(allocator),
        } };
    }

    pub fn deinit(self: *State) void {
        self.arenas[0].deinit();
        self.arenas[1].deinit();
    }

    fn nameError(self: *const State) ?[]const u8 {
        if (self.name_len == 0) return null; // untouched
        if (self.name_len < 3) return "at least 3 characters";
        return null;
    }

    fn emailError(self: *const State) ?[]const u8 {
        if (self.email_len == 0) return null;
        if (std.mem.indexOfScalar(u8, self.email[0..self.email_len], '@') == null)
            return "must contain @";
        return null;
    }

    fn valid(self: *const State) bool {
        return self.name_len >= 3 and
            std.mem.indexOfScalar(u8, self.email[0..self.email_len], '@') != null;
    }

    fn dNameError(self: *const State) ?[]const u8 {
        if (self.d_name_len == 0) return null;
        if (self.d_name_len < 3) return "at least 3 characters";
        return null;
    }

    fn dEmailError(self: *const State) ?[]const u8 {
        if (self.d_email_len == 0) return null;
        if (std.mem.indexOfScalar(u8, self.d_email[0..self.d_email_len], '@') == null)
            return "must contain @";
        return null;
    }

    fn dialogValid(self: *const State) bool {
        return self.d_name_len >= 3 and
            std.mem.indexOfScalar(u8, self.d_email[0..self.d_email_len], '@') != null;
    }
};

pub fn handle(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    if (std.mem.eql(u8, env.event, "join")) {
        return mountForm(h, aa, env);
    }
    if (std.mem.eql(u8, env.event, "input")) {
        return formInput(h, aa, env);
    }
    if (std.mem.eql(u8, env.event, "submit")) {
        return formSubmit(h, aa, env);
    }
    if (std.mem.eql(u8, env.event, "open_dialog")) {
        return openDialog(h, aa, env);
    }
    if (std.mem.eql(u8, env.event, "zc:dialog:close")) {
        return closeDialog(h, aa, env);
    }
    if (std.mem.eql(u8, env.event, "dialog_submit")) {
        return dialogSubmit(h, aa, env);
    }
    return h.sendErr(aa, env, "unknown_event");
}

fn mountForm(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    _ = try h.ensure("form", State, State.init);
    const tree = try renderForm(
        h,
    );
    log.info("mounted {s}", .{topic});
    try h.send(aa, .{
        .type = .message,
        .topic = topic,
        .event = "render",
        .payload = try view.treeToValue(aa, tree),
        .ref = env.ref,
    });
}

fn renderForm(h: *Handler) ![]const view.Segment {
    const f = h.form().?;
    f.active = 1 - f.active;
    var arena = &f.arenas[f.active];
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();

    var children: std.ArrayListUnmanaged(view.Segment) = .empty;
    // dupe into the arena: the previous render tree must stay a true
    // snapshot (the state buffers are edited in place). Escaping is the
    // client's job ({"s": ...} on the wire).
    const name = try a.dupe(u8, f.name[0..f.name_len]);
    const email = try a.dupe(u8, f.email[0..f.email_len]);
    try children.appendSlice(a, try view.TextInput.render(a, .{
        .id = "f-name",
        .value = name,
        .placeholder = "your name",
        .error_msg = f.nameError(),
    }));
    try children.appendSlice(a, try view.TextInput.render(a, .{
        .id = "f-email",
        .value = email,
        .placeholder = "you@example.com",
        .error_msg = f.emailError(),
    }));
    try children.appendSlice(a, try view.Select.render(a, .{
        .id = "f-role",
        .options = &form_options,
        .value = form_options[f.role].value,
    }));
    try children.appendSlice(a, try view.Checkbox.render(a, .{
        .id = "f-sub",
        .label = "Subscribe to the newsletter",
        .checked = f.subscribe,
    }));
    try children.appendSlice(a, try view.SubmitButton.render(a, .{
        .label = "Save",
        .loading = f.submitting,
    }));
    try children.appendSlice(a, try view.Button.render(a, .{
        .label = "Give feedback…",
        .variant = .secondary,
        .on_click = "open_dialog",
    }));
    try children.appendSlice(a, &.{
        .text("<p class=\"status\">"),
        .{ .dynamic = .{ .string = f.status } },
        .text("</p>"),
    });

    const form_tree = try view.Form.render(a, .{
        .id = "f",
        .submitting = f.submitting,
        .children = children.items,
    });
    if (!f.dialog_open) {
        f.trees[f.active] = form_tree;
        return form_tree;
    }

    // portal rule: the dialog is a single node spliced in at view root
    // level, never nested inside the form
    var dialog_children: std.ArrayListUnmanaged(view.Segment) = .empty;
    const d_name = try a.dupe(u8, f.d_name[0..f.d_name_len]);
    const d_email = try a.dupe(u8, f.d_email[0..f.d_email_len]);
    try dialog_children.appendSlice(a, try view.TextInput.render(a, .{
        .id = "d-name",
        .value = d_name,
        .placeholder = "your name",
        .error_msg = f.dNameError(),
    }));
    try dialog_children.appendSlice(a, try view.TextInput.render(a, .{
        .id = "d-email",
        .value = d_email,
        .placeholder = "you@example.com",
        .error_msg = f.dEmailError(),
    }));
    try dialog_children.appendSlice(a, try view.Button.render(a, .{
        .label = "Send",
        .on_click = "dialog_submit",
    }));
    try dialog_children.appendSlice(a, &.{
        .text("<p class=\"status\">"),
        .{ .dynamic = .{ .string = f.dialog_status } },
        .text("</p>"),
    });
    const dialog = try view.Dialog.render(a, .{
        .id = "feedback",
        .title = "Send feedback",
        .children = dialog_children.items,
    });

    // Portal rule: the dialog mounts as ONE root-level children node, so
    // opening/closing it is a single root-level patch.
    const tree = try a.alloc(view.Segment, form_tree.len + 1);
    @memcpy(tree[0..form_tree.len], form_tree);
    tree[form_tree.len] = .{ .children = dialog };
    f.trees[f.active] = tree;
    return tree;
}

fn formInput(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const f = h.form() orelse return h.sendErr(aa, env, "not_joined");
    const id = util.payloadString(env.payload, "id") orelse
        return h.sendErr(aa, env, "malformed");
    const value_str = util.payloadString(env.payload, "value");

    if (std.mem.eql(u8, id, "f-name")) {
        const value = value_str orelse return h.sendErr(aa, env, "malformed");
        if (value.len > f.name.len) return h.sendErr(aa, env, "invalid_value");
        @memcpy(f.name[0..value.len], value);
        f.name_len = value.len;
    } else if (std.mem.eql(u8, id, "f-email")) {
        const value = value_str orelse return h.sendErr(aa, env, "malformed");
        if (value.len > f.email.len) return h.sendErr(aa, env, "invalid_value");
        @memcpy(f.email[0..value.len], value);
        f.email_len = value.len;
    } else if (std.mem.eql(u8, id, "f-role")) {
        const value = value_str orelse return h.sendErr(aa, env, "malformed");
        for (form_options, 0..) |opt, i| {
            if (std.mem.eql(u8, opt.value, value)) {
                f.role = i;
                break;
            }
        }
    } else if (std.mem.eql(u8, id, "d-name")) {
        const value = value_str orelse return h.sendErr(aa, env, "malformed");
        if (value.len > f.d_name.len) return h.sendErr(aa, env, "invalid_value");
        @memcpy(f.d_name[0..value.len], value);
        f.d_name_len = value.len;
    } else if (std.mem.eql(u8, id, "d-email")) {
        const value = value_str orelse return h.sendErr(aa, env, "malformed");
        if (value.len > f.d_email.len) return h.sendErr(aa, env, "invalid_value");
        @memcpy(f.d_email[0..value.len], value);
        f.d_email_len = value.len;
    } else if (std.mem.eql(u8, id, "f-sub")) {
        const p = env.payload orelse return h.sendErr(aa, env, "malformed");
        if (p != .object) return h.sendErr(aa, env, "malformed");
        const v = p.object.get("value") orelse return h.sendErr(aa, env, "malformed");
        if (v != .bool) return h.sendErr(aa, env, "malformed");
        f.subscribe = v.bool;
    } else {
        return h.sendErr(aa, env, "unknown_field");
    }

    const previous = f.trees[f.active];
    const current = try renderForm(
        h,
    );
    var patches = try view.diff(aa, previous, current);
    defer patches.deinit();
    log.info("form input {s}: {d} patch(es)", .{ id, patches.count() });
    try h.send(aa, .{
        .type = .message,
        .topic = topic,
        .event = "patch",
        .payload = try patches.toValue(aa),
        .ref = env.ref,
    });
}

fn formSubmit(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const f = h.form() orelse return h.sendErr(aa, env, "not_joined");
    if (!f.valid()) {
        log.info("form submit rejected: invalid", .{});
        return h.sendErr(aa, env, "invalid_form");
    }
    f.submitting = true;
    f.status = "Saving…";
    try pushFormUpdate(h, aa, env.ref);
    f.submitting = false;
    f.status = "Saved!";
    log.info("form saved", .{});
    try pushFormUpdate(h, aa, env.ref);
}

fn pushFormUpdate(h: *Handler, aa: std.mem.Allocator, ref: ?u64) !void {
    const f = h.form().?;
    const previous = f.trees[f.active];
    const current = try renderForm(
        h,
    );
    var patches = try view.diff(aa, previous, current);
    defer patches.deinit();
    log.info("form: {d} patch(es)", .{patches.count()});
    try h.send(aa, .{
        .type = .message,
        .topic = topic,
        .event = "patch",
        .payload = try patches.toValue(aa),
        .ref = ref,
    });
}

fn openDialog(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const f = h.form() orelse return h.sendErr(aa, env, "not_joined");
    f.dialog_open = true;
    f.dialog_status = "";
    log.info("dialog opened", .{});
    return pushFormUpdate(h, aa, env.ref);
}

fn closeDialog(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const f = h.form() orelse return h.sendErr(aa, env, "not_joined");
    f.dialog_open = false;
    log.info("dialog closed", .{});
    return pushFormUpdate(h, aa, env.ref);
}

fn dialogSubmit(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const f = h.form() orelse return h.sendErr(aa, env, "not_joined");
    if (!f.dialogValid()) {
        f.dialog_status = "Please fix the errors above.";
        log.info("dialog submit rejected: invalid", .{});
        return pushFormUpdate(h, aa, env.ref);
    }
    f.dialog_open = false;
    f.status = "Feedback sent!";
    log.info("feedback sent", .{});
    return pushFormUpdate(h, aa, env.ref);
}
