// Facade over the two libraries: the zlive engine (segment tree, diff,
// JSON conversion) plus the zlive-components library — so view code uses
// one import: `view.Segment`, `view.diff`, `view.Table`, `view.Flash`, ...

const zlive = @import("zlive");
const zlive_components = @import("zlive_components");

pub const Scalar = zlive.Scalar;
pub const Segment = zlive.Segment;
pub const Patch = zlive.Patch;
pub const PatchSet = zlive.PatchSet;
pub const DiffError = zlive.DiffError;
pub const Component = zlive.Component;
pub const diff = zlive.diff;
pub const treeToValue = zlive.treeToValue;
pub const flattenHtml = zlive.flattenHtml;
pub const clearSlot = zlive.clearSlot;
pub const freeValue = zlive.freeValue;

// shadcn's theme registry (the palettes the stylesheet implements).
pub const themes = zlive_components.themes;

pub const Button = zlive_components.Button;
pub const Icon = zlive_components.Icon;
pub const Avatar = zlive_components.Avatar;
pub const Breadcrumb = zlive_components.Breadcrumb;
pub const Collapsible = zlive_components.Collapsible;

// The sidebar block's primitive set (shadcn's `sidebar`).
pub const SidebarProvider = zlive_components.SidebarProvider;
pub const Sidebar = zlive_components.Sidebar;
pub const SidebarLayout = zlive_components.SidebarLayout;
pub const SiteHeader = zlive_components.SiteHeader;
pub const SidebarTrigger = zlive_components.SidebarTrigger;
pub const SidebarRail = zlive_components.SidebarRail;
pub const SidebarInset = zlive_components.SidebarInset;
pub const SidebarHeader = zlive_components.SidebarHeader;
pub const SidebarContent = zlive_components.SidebarContent;
pub const SidebarFooter = zlive_components.SidebarFooter;
pub const SidebarSeparator = zlive_components.SidebarSeparator;
pub const SidebarInput = zlive_components.SidebarInput;
pub const SidebarGroup = zlive_components.SidebarGroup;
pub const SidebarGroupLabel = zlive_components.SidebarGroupLabel;
pub const SidebarGroupAction = zlive_components.SidebarGroupAction;
pub const SidebarGroupContent = zlive_components.SidebarGroupContent;
pub const SidebarMenu = zlive_components.SidebarMenu;
pub const SidebarMenuItem = zlive_components.SidebarMenuItem;
pub const SidebarMenuButton = zlive_components.SidebarMenuButton;
pub const SidebarMenuAction = zlive_components.SidebarMenuAction;
pub const SidebarMenuBadge = zlive_components.SidebarMenuBadge;
pub const SidebarMenuSub = zlive_components.SidebarMenuSub;
pub const SidebarMenuSubItem = zlive_components.SidebarMenuSubItem;
pub const SidebarMenuSubButton = zlive_components.SidebarMenuSubButton;
pub const Flash = zlive_components.Flash;
pub const Toast = zlive_components.Toast;
pub const ToastRegion = zlive_components.ToastRegion;
pub const TextInput = zlive_components.TextInput;
pub const Select = zlive_components.Select;
pub const Checkbox = zlive_components.Checkbox;
pub const Form = zlive_components.Form;
pub const SubmitButton = zlive_components.SubmitButton;
pub const Dialog = zlive_components.Dialog;
pub const Tabs = zlive_components.Tabs;
pub const Accordion = zlive_components.Accordion;
pub const Dropdown = zlive_components.Dropdown;
pub const DropdownPanel = zlive_components.DropdownPanel;
pub const Popover = zlive_components.Popover;
pub const Tooltip = zlive_components.Tooltip;
pub const Table = zlive_components.Table;

// Layout primitives (structure and spacing only).
pub const Card = zlive_components.Card;
pub const Stack = zlive_components.Stack;
pub const Cluster = zlive_components.Cluster;
pub const Grid = zlive_components.Grid;
pub const Container = zlive_components.Container;
pub const Separator = zlive_components.Separator;
