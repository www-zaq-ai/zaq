# Filter-scoped list selection

`ZaqWeb.Helpers.Selection` owns pure selection transitions.
`ZaqWeb.Components.DesignSystem.ListSelection.list_selection/1` renders the
page checkbox, selection bar, all-matching action and clear action. Neither
module knows about People, persistence, or deletion.

## Parent LiveView contract

1. Initialize `Selection.new(filters)` with the complete filter scope. Do not
   include page or page size in the scope.
2. On refresh, call `Selection.scope(selection, filters)`. Identical filters
   preserve selection; changed filters reset it. Do not intersect selection IDs
   with the visible page.
3. Validate row event IDs against the current server-owned rows, then call
   `Selection.toggle/2`. Use `Selection.member?/2` to render row checkboxes.
4. Pass current page IDs to `Selection.toggle_page/2`. A partial page becomes
   fully selected; a fully selected page becomes deselected. Other pages retain
   their selections or exclusions.
5. Offer `Selection.all_matching/1` once the current page is selected and the
   filtered total exceeds the page length. All-matching mode stores exclusions
   only, so browsing does not fetch or retain all matching IDs.
6. Call `Selection.clear/1` for the clear action. Invalidate pending destructive
   confirmation whenever selection or filters change, and when cancelled.

## Rendering

```heex
<ListSelection.list_selection
  id="directory-selection"
  selection={@selection}
  page_ids={Enum.map(@rows, & &1.id)}
  total_count={@total_count}
  page_event="toggle_page"
  all_event="select_all_matching"
  clear_event="clear_selection"
>
  <:actions>
    <Button.button variant={:tertiary} danger phx-click="open_delete">
      Delete selected
    </Button.button>
  </:actions>
</ListSelection.list_selection>
```

The component composes DS Checkbox, Button and Table's selection bar. Event
attributes accept event strings or Phoenix LiveView JS commands. The parent
handles those events and owns domain actions in the `actions` slot.

Give every checkbox a stable unique ID and an accessible label. DS Checkbox's
colocated hook synchronizes native `indeterminate` on mount and update, while
`aria-checked="mixed"` exposes partial selection. Native checkboxes support Space
when focused. Keep row-selection controls separate from row-detail click targets.

Storybook: `storybook/components/list_selection.story.exs` includes empty, none,
partial, full-page, all-matching and exclusion states. Stories illustrate rendered
states; the People LiveView demonstrates event handling.

## Destructive confirmation and live data

The displayed count uses the latest known total and stored IDs. It can become
stale when records change externally, particularly when exclusions no longer
match. It is not an authoritative deletion count.

At modal opening, resolve the selection against the current filters on the
owning service. Freeze the resulting IDs in server-side pending confirmation and
display that snapshot's count. Require that pending confirmation on submit; do
not accept replacement IDs from the browser or rerun the matching query on
confirmation. New matches after modal opening must not join the operation.

People routes `:resolve_selection` through Engine Events and NodeRouter. Its
request carries `mode`, `filters`, and `ids` (inclusions for `:explicit`,
exclusions for `:all_matching`). The query shares listing AND semantics for name,
email, phone, completeness and team; text wildcards are literal, and ordering is
`full_name, id`. Resolution has no pagination.

People's Sage transaction deletes only frozen IDs. Missing targets roll back
the entire batch, including channel cascades. The UI retains selection for
review and clears the failed confirmation; retry requires a new snapshot.
Successful deletion clears selection and clamps the current page to the last
available page.
