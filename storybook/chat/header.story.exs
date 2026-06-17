defmodule Storybook.Chat.Header do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Chat.Header

  def description,
    do: "BO Chat — agent picker and delete control (`ZaqWeb.Chat.Header.chat_header/1`)."

  def render(assigns) do
    agents = [
      %{id: "agent-1", name: "Default answering agent"},
      %{id: "agent-2", name: "Research pipeline"}
    ]

    assigns =
      assigns
      |> assign(:agents, agents)
      |> assign(:agents_solo, [%{id: "agent-1", name: "Solo agent"}])

    ~H"""
    <div
      class="zaq-text-body flex flex-col gap-10"
      style="padding: var(--zaq-scale-32); max-width: 48rem;"
    >
      <section class="flex flex-col gap-2 min-w-0">
        <h2 class="zaq-text-body font-semibold" style="color: var(--zaq-text-color-body-primary);">
          Default pipeline selected
        </h2>
        <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
          Two agents in the list; empty selection uses default pipeline.
        </p>
        <.chat_header selected_agent_id="" available_agents={@agents} />
      </section>

      <section class="flex flex-col gap-2 min-w-0">
        <h2 class="zaq-text-body font-semibold" style="color: var(--zaq-text-color-body-primary);">
          Explicit agent selected
        </h2>
        <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
          Second agent selected.
        </p>
        <.chat_header selected_agent_id="agent-2" available_agents={@agents} />
      </section>

      <section class="flex flex-col gap-2 min-w-0">
        <h2 class="zaq-text-body font-semibold" style="color: var(--zaq-text-color-body-primary);">
          Single custom agent
        </h2>
        <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
          One agent row plus default pipeline option.
        </p>
        <.chat_header selected_agent_id="agent-1" available_agents={@agents_solo} />
      </section>
    </div>
    """
  end
end
