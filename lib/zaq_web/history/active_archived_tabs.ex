defmodule ZaqWeb.History.ActiveArchivedTabs do
  @moduledoc """
  Active / Archived navigation for the BO conversation history page.
  """

  use ZaqWeb, :html

  attr :live_action, :atom,
    required: true,
    doc: "`:archived` on archived route; otherwise active tab."

  def active_archived_tabs(assigns) do
    ~H"""
    <div class="flex items-center gap-1 p-0.5 bg-black/5 rounded-lg w-fit mb-6">
      <.link
        navigate={~p"/bo/history"}
        class={[
          "font-mono text-[0.7rem] px-3 py-1.5 rounded-md transition-all",
          if(@live_action != :archived,
            do: "bg-white text-[#2c3a50] shadow-sm",
            else: "text-black/40 hover:text-black/60"
          )
        ]}
      >
        Active
      </.link>
      <.link
        navigate={~p"/bo/history/archived"}
        class={[
          "font-mono text-[0.7rem] px-3 py-1.5 rounded-md transition-all",
          if(@live_action == :archived,
            do: "bg-white text-[#2c3a50] shadow-sm",
            else: "text-black/40 hover:text-black/60"
          )
        ]}
      >
        Archived
      </.link>
    </div>
    """
  end
end
