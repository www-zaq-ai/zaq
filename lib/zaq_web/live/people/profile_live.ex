defmodule ZaqWeb.Live.People.ProfileLive do
  @moduledoc "Protected People landing scaffold. Profile field editing belongs to PR5."
  use ZaqWeb, :live_view
  alias ZaqWeb.Components.PersonLayout

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Profile")}

  @impl true
  def render(assigns) do
    ~H"""
    <PersonLayout.person_layout flash={@flash} authenticated>
      <section class="zaq-card-default zaq-layout-stack">
        <h1 class="zaq-text-h1">Profile</h1>
        <p class="zaq-text-body">Welcome, {@current_person.full_name}.</p>
        <p class="zaq-text-body">You are signed in to your ZAQ profile.</p>
      </section>
    </PersonLayout.person_layout>
    """
  end
end
