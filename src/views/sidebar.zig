// The sidebar block: shadcn's `sidebar-07` ("a sidebar that collapses to
// icons") as a zlive view.
//
// The interesting part is where the state lives. shadcn keeps `open` in
// React and mirrors it onto `data-state`, then Tailwind's group/peer
// variants reach every descendant. Here the *server* owns it, the provider
// renders it as one attribute, and the CSS in zc.css hangs off that
// attribute — so `zc:sidebar:toggle` is a single patched slot and the whole
// sidebar (gap, width, labels, sub-menus, rail, header height) animates from
// it. Everything else on the page is ordinary view state: which team, which
// nav row is current and expanded, which dropdown is open.
//
// The icon rail is where server state pays off twice: collapsing is still
// one attribute, and because a rail row cannot show a sub-list, the *same*
// `zc:sidebar:nav` event opens the sub-items in a popup beside the rail
// when the sidebar is collapsed. shadcn's icon mode has nowhere for them to
// go; here the server knows the mode, so the row's markup never changes.
//
// Data is the block's sample data (teams, the Platform nav, the Projects
// group, the user), declared here as comptime tables.

const std = @import("std");
const protocol = @import("zlive").protocol;
const view = @import("view");
const util = @import("zlive").util;
const Handler = @import("handler").Handler;

const log = std.log.scoped(.ziggy);

pub const topic = "view:sidebar";

const Provider = view.SidebarProvider;
const Icon = view.Icon;
const MenuItem = view.SidebarMenuItem;
const MenuButton = view.SidebarMenuButton;
const SubButton = view.SidebarMenuSubButton;

// ---------------------------------------------------------------------
// Sample data (shadcn's block data, with lucide icon names)
// ---------------------------------------------------------------------

const Team = struct {
    name: []const u8,
    plan: []const u8,
    icon: Icon.Name,
};

const teams = [_]Team{
    .{ .name = "Acme Inc", .plan = "Enterprise", .icon = .gallery_vertical_end },
    .{ .name = "Acme Corp.", .plan = "Startup", .icon = .audio_waveform },
    .{ .name = "Evil Corp.", .plan = "Free", .icon = .command },
};

const NavItem = struct {
    key: []const u8,
    /// The row's element id, and the anchor its popup menu positions against.
    /// Spelled out rather than built with allocPrint: the popup's panel takes
    /// the id as a plain string, and a comptime literal keeps the render free
    /// of an allocation per row.
    anchor: []const u8,
    title: []const u8,
    icon: Icon.Name,
    sub: []const []const u8,
};

const nav_main = [_]NavItem{
    .{
        .key = "playground",
        .anchor = "sb-nav-playground",
        .title = "Playground",
        .icon = .square_terminal,
        .sub = &.{ "History", "Starred", "Settings" },
    },
    .{
        .key = "models",
        .anchor = "sb-nav-models",
        .title = "Models",
        .icon = .bot,
        .sub = &.{ "Genesis", "Explorer", "Quantum" },
    },
    .{
        .key = "documentation",
        .anchor = "sb-nav-documentation",
        .title = "Documentation",
        .icon = .book_open,
        .sub = &.{ "Introduction", "Get Started", "Tutorials", "Changelog" },
    },
    .{
        .key = "settings",
        .anchor = "sb-nav-settings",
        .title = "Settings",
        .icon = .settings_2,
        .sub = &.{ "General", "Team", "Billing", "Limits" },
    },
};

const Project = struct {
    name: []const u8,
    icon: Icon.Name,
};

const projects = [_]Project{
    .{ .name = "Design Engineering", .icon = .frame },
    .{ .name = "Sales & Marketing", .icon = .pie_chart },
    .{ .name = "Travel", .icon = .map },
};

/// The element ids the project rows' dropdowns anchor to (shadcn uses a
/// ref; a server-rendered panel needs a string).
const project_menu_ids = [_][]const u8{ "sb-project-0", "sb-project-1", "sb-project-2" };

const user_name = "shadcn";
const user_email = "m@example.com";
const user_initials = "CN";

/// Which dropdown is open. A union, not a string: the value arrives from the
/// client, so it is validated into one of these before it is stored.
const Menu = union(enum) {
    none,
    team,
    user,
    project: usize,
    /// A nav row's popup in the icon rail (index into `nav_main`).
    nav: usize,

    fn is(self: Menu, other: Menu) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .project => |i| switch (other) {
                .project => |j| i == j,
                else => false,
            },
            .nav => |i| switch (other) {
                .nav => |j| i == j,
                else => false,
            },
            else => true,
        };
    }

    /// The panel's anchor id (`data-zc-anchor`), which is also the trigger's
    /// element id.
    fn anchor(self: Menu) []const u8 {
        return switch (self) {
            .none => "",
            .team => "sb-team",
            .user => "sb-user",
            .project => |i| project_menu_ids[i],
            .nav => |i| nav_main[i].anchor,
        };
    }

    /// Maps the value a row reports (its element id, which is also the
    /// panel's anchor) back to a Menu.
    fn fromValue(value: []const u8) ?Menu {
        if (std.mem.eql(u8, value, "sb-team") or std.mem.eql(u8, value, "team")) return .team;
        if (std.mem.eql(u8, value, "sb-user") or std.mem.eql(u8, value, "user")) return .user;
        for (project_menu_ids, 0..) |id, i| {
            if (std.mem.eql(u8, value, id)) return .{ .project = i };
        }
        return null;
    }
};

/// Maps a click value to the comptime key it names. The state stores the
/// returned literal, never the envelope's slice (which dies with the
/// request that carried it).
fn keyFor(value: []const u8) ?[]const u8 {
    for (nav_main) |item| {
        if (std.mem.eql(u8, item.key, value)) return item.key;
        for (item.sub) |label| {
            if (std.mem.eql(u8, label, value)) return label;
        }
    }
    for (projects) |project| {
        if (std.mem.eql(u8, project.name, value)) return project.name;
    }
    return null;
}

/// A toggle row's value: "on" / "off" (the layout popover's option rows).
fn onOff(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "on")) return true;
    if (std.mem.eql(u8, value, "off")) return false;
    return null;
}

/// The breadcrumb label for a key: a nav item's title, or the key itself
/// (sub-items and projects are already display text).
fn labelFor(key: []const u8) []const u8 {
    for (nav_main) |item| {
        if (std.mem.eql(u8, item.key, key)) return item.title;
    }
    return key;
}

pub const State = struct {
    /// The sidebar itself: one bool, one attribute, one patch.
    open: bool = true,
    side: Provider.Side = .left,
    variant: Provider.Variant = .sidebar,
    /// The layout options, as `SidebarLayout` props. `mini` is the block's
    /// "collapse to icons" (shadcn's collapsible="icon") versus hiding the
    /// sidebar outright (offcanvas); `header_placement` puts the header
    /// across the top (sidebar-16) or inside the content column
    /// (sidebar-07); `sticky_header` is the header's `sticky` prop (the
    /// full-width header is always sticky).
    mini: bool = true,
    header_placement: view.SidebarLayout.HeaderPlacement = .full,
    sticky_header: bool = true,
    /// The demo's layout popover (a second use of the overlay primitives).
    layout_open: bool = false,

    active_team: usize = 0,
    /// Disclosure state per nav item; the active one starts open, as in the
    /// block.
    nav_open: [nav_main.len]bool = .{ true, false, false, false },
    /// The current row: drives the nav highlight and the breadcrumb page.
    active_key: []const u8 = "playground",
    /// The open dropdown, if any.
    open_menu: Menu = .none,

    arenas: [2]std.heap.ArenaAllocator,
    trees: [2][]const view.Segment = .{ &.{}, &.{} },
    active: usize = 0,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .arenas = .{
            std.heap.ArenaAllocator.init(allocator),
            std.heap.ArenaAllocator.init(allocator),
        } };
    }

    pub fn deinit(self: *State) void {
        self.arenas[0].deinit();
        self.arenas[1].deinit();
    }
};

pub fn handle(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    if (std.mem.eql(u8, env.event, "join")) {
        return mount(h, aa, env);
    }
    const state = h.sidebar() orelse return h.sendErr(aa, env, "not_joined");
    const event = env.event;

    if (std.mem.eql(u8, event, "zc:sidebar:toggle")) {
        state.open = !state.open;
        state.open_menu = .none; // a collapsing sidebar takes its menus with it
    } else if (std.mem.eql(u8, event, "zc:sidebar:side")) {
        const value = util.payloadString(env.payload, "value") orelse
            return h.sendErr(aa, env, "malformed");
        state.side = Provider.Side.fromTag(value) orelse
            return h.sendErr(aa, env, "invalid_value");
    } else if (std.mem.eql(u8, event, "zc:sidebar:variant")) {
        const value = util.payloadString(env.payload, "value") orelse
            return h.sendErr(aa, env, "malformed");
        state.variant = Provider.Variant.fromTag(value) orelse
            return h.sendErr(aa, env, "invalid_value");
    } else if (std.mem.eql(u8, event, "zc:sidebar:mini")) {
        const value = util.payloadString(env.payload, "value") orelse
            return h.sendErr(aa, env, "malformed");
        state.mini = onOff(value) orelse
            return h.sendErr(aa, env, "invalid_value");
        // Without the rail, the nav popups anchor to rows nobody can see.
        if (!state.mini) state.open_menu = .none;
    } else if (std.mem.eql(u8, event, "zc:sidebar:placement")) {
        const value = util.payloadString(env.payload, "value") orelse
            return h.sendErr(aa, env, "malformed");
        state.header_placement = view.SidebarLayout.HeaderPlacement.fromTag(value) orelse
            return h.sendErr(aa, env, "invalid_value");
    } else if (std.mem.eql(u8, event, "zc:sidebar:sticky")) {
        const value = util.payloadString(env.payload, "value") orelse
            return h.sendErr(aa, env, "malformed");
        state.sticky_header = onOff(value) orelse
            return h.sendErr(aa, env, "invalid_value");
    } else if (std.mem.eql(u8, event, "zc:sidebar:nav")) {
        // A nav row is both a link and a disclosure: it becomes the current
        // row and toggles its sub-items, which is what shadcn's does. In the
        // icon rail there is nowhere to show the sub-list, so the same click
        // opens it in a popup beside the rail instead — the row's markup does
        // not change, which is why collapsing to icons stays one patch.
        const value = util.payloadString(env.payload, "value") orelse
            return h.sendErr(aa, env, "malformed");
        var found = false;
        for (nav_main, 0..) |item, i| {
            if (!std.mem.eql(u8, item.key, value)) continue;
            if (!state.open and state.mini) {
                const menu: Menu = .{ .nav = i };
                state.open_menu = if (state.open_menu.is(menu)) .none else menu;
            } else {
                state.nav_open[i] = !state.nav_open[i];
                state.active_key = item.key;
            }
            found = true;
        }
        if (!found) return h.sendErr(aa, env, "invalid_value");
    } else if (std.mem.eql(u8, event, "zc:sidebar:select")) {
        const value = util.payloadString(env.payload, "value") orelse
            return h.sendErr(aa, env, "malformed");
        state.active_key = keyFor(value) orelse
            return h.sendErr(aa, env, "invalid_value");
        // A sub-item is a destination: picking one from the rail's popup
        // closes the popup, like any menu row that navigates.
        state.open_menu = .none;
    } else if (std.mem.eql(u8, event, "zc:sidebar:team")) {
        const value = util.payloadString(env.payload, "value") orelse
            return h.sendErr(aa, env, "malformed");
        const index = std.fmt.parseInt(usize, value, 10) catch
            return h.sendErr(aa, env, "invalid_value");
        if (index >= teams.len) return h.sendErr(aa, env, "invalid_value");
        state.active_team = index;
        state.open_menu = .none;
    } else if (std.mem.eql(u8, event, "zc:sidebar:menu")) {
        // A menu row (project action, account, log out): the demo has no
        // pages behind them, so the row just closes its menu.
        state.open_menu = .none;
    } else if (std.mem.eql(u8, event, "zc:dropdown:toggle")) {
        const value = util.payloadString(env.payload, "value") orelse
            return h.sendErr(aa, env, "malformed");
        const menu = Menu.fromValue(value) orelse
            return h.sendErr(aa, env, "invalid_value");
        state.open_menu = if (state.open_menu.is(menu)) .none else menu;
    } else if (std.mem.eql(u8, event, "zc:dropdown:close")) {
        state.open_menu = .none;
    } else if (std.mem.eql(u8, event, "zc:popover:toggle")) {
        state.layout_open = !state.layout_open;
    } else if (std.mem.eql(u8, event, "zc:popover:close")) {
        state.layout_open = false;
    } else {
        return h.sendErr(aa, env, "unknown_event");
    }

    return pushUpdate(h, aa, env.ref);
}

fn mount(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const state = try h.ensure("sidebar", State, State.init);
    // The page carries the sidebar's last state in a cookie (shadcn does the
    // same) and passes it in the join payload, so a reload comes back the way
    // it was left.
    if (util.payloadString(env.payload, "sidebar")) |value| {
        state.open = !std.mem.eql(u8, value, "0");
    }
    h.app().lock();
    const json = blk: {
        defer h.app().unlock();
        const tree = try render(state);
        log.info("mounted {s}", .{topic});
        const reply = protocol.Envelope{
            .type = .message,
            .topic = topic,
            .event = "render",
            .payload = try view.treeToValue(aa, tree),
            .ref = env.ref,
        };
        break :blk try reply.encode(aa);
    };
    try h.service.conn.write(json);
}

fn pushUpdate(h: *Handler, aa: std.mem.Allocator, ref: ?u64) !void {
    const state = h.sidebar().?;
    h.app().lock();
    const json = blk: {
        defer h.app().unlock();
        const previous = state.trees[state.active];
        const current = try render(state);
        var patches = try view.diff(aa, previous, current);
        defer patches.deinit();
        log.info("sidebar: {d} patch(es)", .{patches.count()});
        const reply = protocol.Envelope{
            .type = .message,
            .topic = topic,
            .event = "patch",
            .payload = try patches.toValue(aa),
            .ref = ref,
        };
        break :blk try reply.encode(aa);
    };
    try h.service.conn.write(json);
}

// ---------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------

const Segs = std.ArrayListUnmanaged(view.Segment);

/// Turns rendered components into one `children` list. Segments are borrowed
/// by reference, so every list that holds runtime values has to be
/// arena-owned — hence this helper instead of `&.{...}` literals.
fn children(a: std.mem.Allocator, parts: []const []const view.Segment) ![]const view.Segment {
    var list: Segs = .empty;
    for (parts) |part| try list.append(a, .{ .children = part });
    return list.toOwnedSlice(a);
}

fn one(a: std.mem.Allocator, part: []const view.Segment) ![]const view.Segment {
    const out = try a.alloc(view.Segment, 1);
    out[0] = .{ .children = part };
    return out;
}

/// One segment as an arena-owned list, for a component whose slot is a plain
/// list (a group label, a header's text).
fn child(a: std.mem.Allocator, seg: view.Segment) ![]const view.Segment {
    const out = try a.alloc(view.Segment, 1);
    out[0] = seg;
    return out;
}

fn render(state: *State) ![]const view.Segment {
    state.active = 1 - state.active;
    var arena = &state.arenas[state.active];
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();

    // The sidebar's parts, in shadcn's order: header (team switcher),
    // content (Platform nav + projects), footer (user), rail.
    var content: Segs = .empty;
    try content.append(a, .{ .children = try navGroup(a, state, "Platform") });
    try content.append(a, .{ .children = try projectsGroup(a, state) });

    const sidebar_tree = try children(a, &.{
        try view.SidebarHeader.render(a, .{ .children = try one(a, try teamSwitcher(a, state)) }),
        try view.SidebarContent.render(a, .{ .children = try content.toOwnedSlice(a) }),
        try view.SidebarFooter.render(a, .{ .children = try one(a, try footerUser(a, state)) }),
        try view.SidebarRail.render(a, .{}),
    });

    // The layout popover is one render: [trigger segments..., panel node].
    // The trigger goes in the header slot, the panel is portaled to the root.
    const popover = try layoutPopover(a, state);

    var root: Segs = .empty;
    try root.append(a, .{ .children = try view.SidebarLayout.render(a, .{
        .open = state.open,
        .side = state.side,
        .variant = state.variant,
        .mini = state.mini,
        .header_placement = state.header_placement,
        .sticky_header = state.sticky_header,
        .header = try headerContents(a, state, popover[0 .. popover.len - 1]),
        .sidebar = sidebar_tree,
        .content = try insetBody(a),
    }) });

    // Portaled overlays: a dropdown panel is fixed-positioned against its
    // trigger by the hook, so it lives at the root like the kitchen sink's.
    if (!state.open_menu.is(.none)) {
        try root.append(a, .{ .children = try menuPanel(a, state) });
    }
    if (state.layout_open) {
        try root.append(a, popover[popover.len - 1]);
    }

    const tree = try root.toOwnedSlice(a);
    state.trees[state.active] = tree;
    return tree;
}

fn teamSwitcher(a: std.mem.Allocator, state: *State) ![]const view.Segment {
    const team = teams[state.active_team];
    var row: Segs = .empty;
    try row.append(a, .text("<span class=\"dash-logo\">"));
    try row.appendSlice(a, try Icon.render(a, .{ .name = team.icon }));
    try row.append(a, .text("</span><span class=\"dash-lines zc-hide-collapsed\"><span class=\"dash-name\">"));
    try row.append(a, .{ .dynamic = .{ .string = team.name } });
    try row.append(a, .text("</span><span class=\"dash-line-sub\">"));
    try row.append(a, .{ .dynamic = .{ .string = team.plan } });
    try row.append(a, .text("</span></span>"));
    try row.appendSlice(a, try Icon.render(a, .{ .name = .chevrons_up_down, .class = "zc-sidebar-chevron" }));

    const button = try MenuButton.render(a, .{
        .id = "sb-team",
        .size = .lg,
        .children = try row.toOwnedSlice(a),
        .event = "zc:dropdown:toggle",
        .value = "sb-team",
        .expanded = state.open_menu.is(.team),
        .title = "Switch team",
    });
    const item = try MenuItem.render(a, .{ .children = try one(a, button) });
    return view.SidebarMenu.render(a, .{ .children = try one(a, item) });
}

fn navGroup(a: std.mem.Allocator, state: *State, label: []const u8) ![]const view.Segment {
    var rows: Segs = .empty;
    for (nav_main, 0..) |entry, i| {
        var sub_items: Segs = .empty;
        for (entry.sub) |sub| {
            const sub_button = try SubButton.render(a, .{
                .label = sub,
                .href = "#",
                .active = std.mem.eql(u8, state.active_key, sub),
                .event = "zc:sidebar:select",
                .value = sub,
            });
            const sub_item = try view.SidebarMenuSubItem.render(a, .{
                .children = try one(a, sub_button),
            });
            try sub_items.append(a, .{ .children = sub_item });
        }

        var children_list: Segs = .empty;
        try children_list.append(a, .{ .children = try MenuButton.render(a, .{
            .id = entry.anchor,
            .label = entry.title,
            .icon = entry.icon,
            .chevron = true,
            .active = std.mem.eql(u8, state.active_key, entry.key),
            .expanded = state.nav_open[i],
            .event = "zc:sidebar:nav",
            .value = entry.key,
            .title = entry.title,
        }) });
        try children_list.append(a, .{ .children = try view.SidebarMenuSub.render(a, .{
            .children = try sub_items.toOwnedSlice(a),
        }) });

        try rows.append(a, .{ .children = try MenuItem.render(a, .{
            .open = state.nav_open[i],
            .children = try children_list.toOwnedSlice(a),
        }) });
    }

    const menu = try view.SidebarMenu.render(a, .{ .children = try rows.toOwnedSlice(a) });
    const group_label = try view.SidebarGroupLabel.render(a, .{
        .children = try child(a, .text(label)),
    });
    return view.SidebarGroup.render(a, .{ .children = try children(a, &.{ group_label, menu }) });
}

fn projectsGroup(a: std.mem.Allocator, state: *State) ![]const view.Segment {
    var rows: Segs = .empty;
    for (projects, 0..) |project, i| {
        var row: Segs = .empty;
        try row.append(a, .{ .children = try MenuButton.render(a, .{
            .label = project.name,
            .icon = project.icon,
            .href = "#",
            .active = std.mem.eql(u8, state.active_key, project.name),
            .event = "zc:sidebar:select",
            .value = project.name,
            .title = project.name,
        }) });
        try row.append(a, .{ .children = try view.SidebarMenuAction.render(a, .{
            .id = project_menu_ids[i],
            .show_on_hover = true,
            .value = project_menu_ids[i],
        }) });
        try rows.append(a, .{ .children = try MenuItem.render(a, .{
            .children = try row.toOwnedSlice(a),
        }) });
    }
    // The block's trailing "More" row.
    try rows.append(a, .{ .children = try MenuItem.render(a, .{
        .children = try one(a, try MenuButton.render(a, .{
            .label = "More",
            .icon = .more_horizontal,
            .event = "zc:sidebar:menu",
            .class = "dash-muted-row",
        })),
    }) });

    const menu = try view.SidebarMenu.render(a, .{ .children = try rows.toOwnedSlice(a) });
    const label = try view.SidebarGroupLabel.render(a, .{
        .children = try child(a, .text("Projects")),
    });
    // `zc-hide-collapsed`: the whole group disappears in the icon rail, which
    // is shadcn's `group-data-[collapsible=icon]:hidden` on this group.
    return view.SidebarGroup.render(a, .{
        .class = "zc-hide-collapsed",
        .children = try children(a, &.{ label, menu }),
    });
}

fn footerUser(a: std.mem.Allocator, state: *State) ![]const view.Segment {
    var row: Segs = .empty;
    try row.appendSlice(a, try view.Avatar.render(a, .{
        .fallback = user_initials,
        .class = "zc-avatar-square",
    }));
    try row.append(a, .text("<span class=\"dash-lines zc-hide-collapsed\"><span class=\"dash-name\">"));
    try row.append(a, .{ .dynamic = .{ .string = user_name } });
    try row.append(a, .text("</span><span class=\"dash-line-sub\">"));
    try row.append(a, .{ .dynamic = .{ .string = user_email } });
    try row.append(a, .text("</span></span>"));
    try row.appendSlice(a, try Icon.render(a, .{ .name = .chevrons_up_down, .class = "zc-sidebar-chevron" }));

    const button = try MenuButton.render(a, .{
        .id = "sb-user",
        .size = .lg,
        .children = try row.toOwnedSlice(a),
        .event = "zc:dropdown:toggle",
        .value = "sb-user",
        .expanded = state.open_menu.is(.user),
        .title = "Account",
    });
    const item = try MenuItem.render(a, .{ .children = try one(a, button) });
    return view.SidebarMenu.render(a, .{ .children = try one(a, item) });
}

/// The header bar's contents. `SidebarLayout` owns the frame (height, rule,
/// background, stickiness); this is what sits in it — the trigger, the
/// vertical rule, the breadcrumb, and the demo's two controls on the right.
fn headerContents(
    a: std.mem.Allocator,
    state: *State,
    popover_trigger: []const view.Segment,
) ![]const view.Segment {
    var bar: Segs = .empty;
    try bar.append(a, .{ .children = try view.SidebarTrigger.render(a, .{}) });
    try bar.append(a, .{ .children = try view.Separator.render(a, .{
        .orientation = .vertical,
        .class = "dash-header-sep",
    }) });
    try bar.append(a, .{ .children = try view.Breadcrumb.render(a, .{
        .trail = try a.dupe(view.Breadcrumb.Item, &.{
            .{ .label = "Build Your Application", .href = "#" },
        }),
        .page = labelFor(state.active_key),
        .class = "dash-crumb",
    }) });
    try bar.append(a, .text("<span class=\"dash-spacer\"></span>"));
    try bar.append(a, .{ .children = popover_trigger });
    try bar.append(a, .text("<button type=\"button\" class=\"btn\" data-variant=\"ghost\" data-size=\"sm\" onclick=\"zcTheme.toggle()\">theme</button>"));
    return bar.toOwnedSlice(a);
}

fn insetBody(a: std.mem.Allocator) ![]const view.Segment {
    var body: Segs = .empty;
    try body.append(a, .text("<div class=\"dash-body\"><div class=\"dash-grid\">"));
    for (0..3) |_| try body.append(a, .text("<div class=\"dash-card\"></div>"));
    try body.append(a, .text("</div><div class=\"dash-panel\"></div></div>"));
    return body.toOwnedSlice(a);
}

/// The layout popover: the demo's configuration, in an overlay rather than
/// in the header (which stays close to the block). Every row is a prop of
/// the frame components — `SidebarLayout` for the sidebar options,
/// `SiteHeader` for the header's. Returns [trigger segments..., panel]: the
/// trigger goes in the header slot, the panel is portaled to the root.
fn layoutPopover(a: std.mem.Allocator, state: *State) ![]const view.Segment {
    var panel: Segs = .empty;
    try panel.append(a, .text("<p class=\"dash-pop-title\">Sidebar</p>"));
    try panel.append(a, .{ .children = try optionRow(a, "Side", try optionButtons(a,
        "zc:sidebar:side", &.{ "left", "right" }, &.{ state.side == .left, state.side == .right })) });
    try panel.append(a, .{ .children = try optionRow(a, "Variant", try optionButtons(a,
        "zc:sidebar:variant", &.{ "sidebar", "floating", "inset" },
        &.{ state.variant == .sidebar, state.variant == .floating, state.variant == .inset })) });
    try panel.append(a, .{ .children = try optionRow(a, "Mini sidebar", try optionButtons(a,
        "zc:sidebar:mini", &.{ "off", "on" }, &.{ !state.mini, state.mini })) });
    try panel.append(a, .text("<p class=\"dash-pop-title\">Header</p>"));
    try panel.append(a, .{ .children = try optionRow(a, "Placement", try optionButtons(a,
        "zc:sidebar:placement", &.{ "inset", "full" },
        &.{ state.header_placement == .inset, state.header_placement == .full })) });
    if (state.header_placement == .inset) {
        // The full-width header is sticky by construction: it is the offset
        // the sidebar is pinned below.
        try panel.append(a, .{ .children = try optionRow(a, "Sticky", try optionButtons(a,
            "zc:sidebar:sticky", &.{ "off", "on" },
            &.{ !state.sticky_header, state.sticky_header })) });
    }
    try panel.append(a, .text("<p class=\"dash-pop-note\">The frame is two components — " ++
        "SidebarLayout and SiteHeader — and these rows are their props.</p>"));
    return view.Popover.render(a, .{
        .id = "sb-layout",
        .label = "Layout",
        .open = state.layout_open,
        .placement = "bottom-end",
        .children = try panel.toOwnedSlice(a),
    });
}

/// A labeled option row: `<span>label</span><span>buttons…</span>`.
fn optionRow(
    a: std.mem.Allocator,
    label: []const u8,
    buttons: []const view.Segment,
) ![]const view.Segment {
    var row: Segs = .empty;
    try row.append(a, .text("<div class=\"dash-pop-row\"><span class=\"dash-pop-label\">"));
    try row.append(a, .text(label));
    try row.append(a, .text("</span><span class=\"dash-pop-opts\">"));
    try row.append(a, .{ .children = buttons });
    try row.append(a, .text("</span></div>"));
    return row.toOwnedSlice(a);
}

fn optionButtons(
    a: std.mem.Allocator,
    event: []const u8,
    labels: []const []const u8,
    active: []const bool,
) ![]const view.Segment {
    var list: Segs = .empty;
    for (labels, 0..) |label, i| {
        try list.appendSlice(a, try view.Button.render(a, .{
            .label = label,
            .variant = if (active[i]) .@"default" else .outline,
            .size = .sm,
            .on_click = event,
            .value = label,
        }));
    }
    return list.toOwnedSlice(a);
}

fn menuPanel(a: std.mem.Allocator, state: *State) ![]const view.Segment {
    const items = switch (state.open_menu) {
        .none => unreachable,
        .team => try teamMenuItems(a),
        .user => try userMenuItems(a),
        .project => |i| try projectMenuItems(a, projects[i].name),
        .nav => |i| try navMenuItems(a, state, i),
    };
    return view.DropdownPanel.render(a, .{
        .id = state.open_menu.anchor(),
        .items = items,
        .placement = "right-start",
        .open_sub = null,
    });
}

fn teamMenuItems(a: std.mem.Allocator) ![]const view.Dropdown.Item {
    var list: std.ArrayListUnmanaged(view.Dropdown.Item) = .empty;
    try list.append(a, .{ .kind = .label, .label = "Teams" });
    for (teams, 0..) |team, i| {
        try list.append(a, .{
            .label = team.name,
            .event = "zc:sidebar:team",
            .value = try std.fmt.allocPrint(a, "{d}", .{i}),
            .shortcut = try std.fmt.allocPrint(a, "⌘{d}", .{i + 1}),
        });
    }
    try list.append(a, .{ .kind = .separator });
    try list.append(a, .{ .label = "Add team", .event = "zc:sidebar:menu", .value = "add" });
    return list.toOwnedSlice(a);
}

fn userMenuItems(a: std.mem.Allocator) ![]const view.Dropdown.Item {
    var list: std.ArrayListUnmanaged(view.Dropdown.Item) = .empty;
    try list.append(a, .{ .kind = .label, .label = user_name });
    try list.append(a, .{ .kind = .label, .label = user_email });
    try list.append(a, .{ .kind = .separator });
    try list.append(a, .{ .label = "Upgrade to Pro", .event = "zc:sidebar:menu", .value = "upgrade" });
    try list.append(a, .{ .kind = .separator });
    try list.append(a, .{ .label = "Account", .event = "zc:sidebar:menu", .value = "account" });
    try list.append(a, .{ .label = "Billing", .event = "zc:sidebar:menu", .value = "billing" });
    try list.append(a, .{ .label = "Notifications", .event = "zc:sidebar:menu", .value = "notifications" });
    try list.append(a, .{ .kind = .separator });
    try list.append(a, .{ .label = "Log out", .event = "zc:sidebar:menu", .value = "logout" });
    return list.toOwnedSlice(a);
}

fn projectMenuItems(a: std.mem.Allocator, name: []const u8) ![]const view.Dropdown.Item {
    var list: std.ArrayListUnmanaged(view.Dropdown.Item) = .empty;
    try list.append(a, .{ .kind = .label, .label = name });
    try list.append(a, .{ .kind = .separator });
    try list.append(a, .{ .label = "View Project", .event = "zc:sidebar:menu", .value = "view" });
    try list.append(a, .{ .label = "Share Project", .event = "zc:sidebar:menu", .value = "share" });
    try list.append(a, .{ .kind = .separator });
    try list.append(a, .{
        .label = "Delete Project",
        .event = "zc:sidebar:menu",
        .value = "delete",
        .variant = .destructive,
    });
    return list.toOwnedSlice(a);
}

/// The mini rail's nav popup: the row's title, then its sub-items, with the
/// current one marked. These are radio rows because exactly one sub-item is
/// the current page — the server owns which, like every other menu state.
fn navMenuItems(a: std.mem.Allocator, state: *State, index: usize) ![]const view.Dropdown.Item {
    const item = nav_main[index];
    var list: std.ArrayListUnmanaged(view.Dropdown.Item) = .empty;
    try list.append(a, .{ .kind = .label, .label = item.title });
    try list.append(a, .{ .kind = .separator });
    for (item.sub) |sub| {
        try list.append(a, .{
            .kind = .radio,
            .label = sub,
            .event = "zc:sidebar:select",
            .value = sub,
            .checked = std.mem.eql(u8, state.active_key, sub),
        });
    }
    return list.toOwnedSlice(a);
}

const testing = std.testing;

test "the menu union validates what the client sends" {
    try testing.expect(Menu.fromValue("team").?.is(.team));
    try testing.expect(Menu.fromValue("sb-project-2").?.is(.{ .project = 2 }));
    try testing.expect(!Menu.fromValue("sb-project-2").?.is(.{ .project = 1 }));
    try testing.expect(Menu.fromValue("bogus") == null);
    try testing.expect(@as(Menu, .none).is(.none));
    try testing.expect(!@as(Menu, .none).is(.team));
    try testing.expectEqualStrings("sb-user", @as(Menu, .user).anchor());
}

test "the rail's nav popups are distinct menus with the row's own anchor" {
    // The popup is anchored to the row it came from, so two rows' popups are
    // two different menu states (and opening one closes the other).
    const first: Menu = .{ .nav = 0 };
    const second: Menu = .{ .nav = 1 };
    try testing.expect(first.is(.{ .nav = 0 }));
    try testing.expect(!first.is(second));
    try testing.expect(!second.is(.team));
    try testing.expect(!first.is(.none));
    try testing.expectEqualStrings("sb-nav-playground", first.anchor());
    try testing.expectEqualStrings("sb-nav-models", second.anchor());
    // The anchor is the row's element id: the client looks it up by id.
    try testing.expectEqualStrings(nav_main[2].anchor, @as(Menu, .{ .nav = 2 }).anchor());
    // A copy-paste in the table would point a popup at the wrong row.
    for (nav_main, 0..) |item, i| {
        try testing.expectEqualStrings(item.anchor, @as(Menu, .{ .nav = i }).anchor());
        for (nav_main[i + 1 ..]) |later| {
            try testing.expect(!std.mem.eql(u8, item.anchor, later.anchor));
        }
    }
}

test "a click value is stored as a comptime key, never the request slice" {
    // The state keeps a pointer into the tables below, so it outlives the
    // envelope's arena.
    try testing.expectEqualStrings("models", keyFor("models").?);
    try testing.expectEqualStrings("Changelog", keyFor("Changelog").?);
    try testing.expectEqualStrings("Travel", keyFor("Travel").?);
    try testing.expect(keyFor("nope") == null);
    try testing.expectEqualStrings("Playground", labelFor("playground"));
    try testing.expectEqualStrings("Billing", labelFor("Billing"));
}

test "the layout options accept on/off and nothing else" {
    try testing.expect(onOff("on").? == true);
    try testing.expect(onOff("off").? == false);
    try testing.expect(onOff("yes") == null);
    try testing.expect(onOff("") == null);
}
