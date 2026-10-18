// The app's notification queues.
//
// Both are the framework's auto-dismiss queue (zlive/src/notify.zig),
// parameterized with this app's context and a component's props. They are
// separate queues on purpose: the inline Flash banner and the corner Toast
// stack are independent notices, and one shared queue would render the same
// message in both places at once.
//
// A queue owns its messages, times them out on its own reaper thread, and
// re-renders this connection's view through `Handler.flush` when one
// expires — the app never computes a patch for a notification, so nothing
// here needs to know where in the tree a message is rendered.

const zlive = @import("zlive");
const App = @import("main").App;
const view = @import("view");

/// The inline banner: one at a time, so showing a second replaces the first
/// (the queue evicts its oldest when it is full).
pub const Banner = zlive.http.Queue(App, view.Flash.Props, 1);

/// The corner stack: three at a time, each with its own deadline, each
/// dismissible on its own.
pub const Toast = zlive.http.Queue(App, view.Toast.Props, 3);
