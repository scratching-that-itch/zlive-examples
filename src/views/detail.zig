// The master-detail panel shared by the countries page and the kitchen
// sink's table section: a Card whose body is the selected country's facts.
//
// Kept out of either view module so the two renderings stay identical (the
// kitchen sink asserts that with e2e checks on the detail slot's markup).

const std = @import("std");
const view = @import("view");
const countries_data = @import("countries_data");

/// The DOM id and hook class of the detail card. Both are part of the page
/// contract: the dismiss patch clears the slot, and the CSS positions the
/// close button relative to the card.
pub const card_id = "detail";
pub const close_class = "detail-close";

/// Column sort state, shared with the country table so both views can pass
/// the same value (`countries.CountrySort` is this type).
pub const Sort = struct { col: usize, asc: bool };

/// The dimensions the panel is rendered from.
pub const State = struct {
    selected: ?usize,
    /// Carried so the panel can show sort context; selection is by index,
    /// so sorting never changes which country is shown.
    sort: Sort,
};

/// Builds the detail panel for the current selection. Returns a `.children`
/// segment holding either the Card or nothing (nothing selected).
pub fn render(a: std.mem.Allocator, state: State) !view.Segment {
    const i = state.selected orelse return .{ .children = &.{} };
    const country = countries_data.countries[i];
    _ = state.sort; // selection is index-based; sorting never changes it

    // Facts as a definition list; the Card owns the surface and header.
    var body: std.ArrayListUnmanaged(view.Segment) = .empty;
    try body.append(a, .text("<dl>"));
    const fields = [_][2][]const u8{
        .{ "Capital", country.capital },
        .{ "Region", country.region },
        .{ "Population", try countries_data.formatPop(a, country.pop) },
        .{ "Area", try std.fmt.allocPrint(a, "{d} km²", .{country.area_km2}) },
        .{ "Language", country.language },
    };
    for (fields) |field| {
        try body.append(a, .text("<dt>"));
        try body.append(a, .{ .dynamic = .{ .string = field[0] } });
        try body.append(a, .text("</dt><dd>"));
        try body.append(a, .{ .dynamic = .{ .string = field[1] } });
        try body.append(a, .text("</dd>"));
    }
    try body.append(a, .text("</dl>"));

    // Children: the close button, then the facts. The close button is a
    // Button (shadcn's dialog close is a ghost icon button); `close_class`
    // only positions it — the variant classes stay, which is the additive
    // `class` contract.
    var children: std.ArrayListUnmanaged(view.Segment) = .empty;
    try children.appendSlice(a, try view.Button.render(a, .{
        .label = "×",
        .variant = .ghost,
        .size = .@"icon-sm",
        .class = close_class,
        .on_click = "close_details",
        .aria_label = "Close",
    }));
    try children.append(a, .{ .children = body.items });

    const card = try view.Card.render(a, .{
        .title = country.name,
        .children = children.items,
        .id = card_id,
        // The server replaces this card's content on every selection, so it
        // is an ARIA live region (as the hand-written markup was).
        .live = true,
    });
    return .{ .children = card };
}
