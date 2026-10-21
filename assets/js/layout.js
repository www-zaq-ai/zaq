// Sidebar collapse is client-owned UI state. Keep it when LiveView replaces
// layout attributes; all other classes still come from the server patch.
export function preserveSidebarState(from, to) {
  if (from.id === "bo-sidebar" || from.id === "bo-main") {
    to.classList.toggle("collapsed", from.classList.contains("collapsed"))
  }
}
