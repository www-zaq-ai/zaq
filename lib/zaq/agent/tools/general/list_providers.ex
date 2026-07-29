defmodule Zaq.Agent.Tools.General.ListProviders do
  @moduledoc """
  ReAct tool: lists the channel providers available for a given channel kind.

  Lives under `General` rather than `DataSource` because it spans channel
  kinds — the same menu answers "where can this document go?" and "where can
  this message go?".

  Exists so the agent can ask the user *where* something should go instead of
  guessing a provider key — `Zaq.Agent.Tools.DataSource.CreateDocument`
  requires an explicit provider and never assumes one.

  The `kind` input decides which menu is returned:

  - `"data_source"` — providers a document can be written to (always includes
    `"disk"`, the local ZAQ volume).
  - `"communication"` — providers a message can be sent through.

  Every entry carries a `status` so the agent can tell a channel that is usable
  now (`:active`) from one that exists but is switched off (`:inactive`) — see
  `Zaq.Channels.Bridge.list_providers/2`.

  Delegates to Channels through `NodeRouter.dispatch/1`.

  ## Expected context keys

  - `:node_router` — override the NodeRouter module (default `Zaq.NodeRouter`).
  """

  use Zaq.Engine.Workflows.Action,
    name: "list_channel_providers",
    description: """
    List the channel providers available for a given channel kind.

    USE THIS TOOL before creating a document — or before sending a message —
    when the user has not said where it should go: create_document requires an
    explicit provider and never picks one for you. Present the returned labels
    and let the user choose.

    Pass kind "data_source" for places a document can be written to, or
    "communication" for places a message can be sent through.

    Each entry has a `provider` key (pass this to create_document), a
    human-readable `label` (show this to the user), and a `status`:

    - "active" — the channel has an enabled configuration and can be used now.
    - "inactive" — the channel is configured but switched off. Do NOT send to
      it. Tell the user it is turned off and needs enabling in the settings.

    Only offer active providers as choices. For kind "data_source", "disk" is
    the local ZAQ volume and is always active, even with no connectors
    configured. A provider that was never configured is not listed at all.
    """,
    schema: [
      kind: [
        type: {:in, ["data_source", "communication"]},
        required: true,
        doc:
          ~s|Channel kind to list providers for: "data_source" for document | <>
            ~s|destinations, "communication" for message destinations|
      ]
    ],
    output_schema: [
      providers: [
        type: {:list, :map},
        required: true,
        doc:
          ~s|Provider menu — each entry has a `provider` key, a `label`, and a | <>
            ~s|`status` of "active" (usable now) or "inactive" (configured but off)|
      ]
    ]

  alias Zaq.Agent.Tools.ChannelTool

  @impl Jido.Action
  def run(%{kind: kind}, context) do
    ChannelTool.dispatch(
      :channel_list_providers,
      %{kind: kind_atom(kind)},
      context,
      "Channel provider listing failed"
    )
  end

  defp kind_atom("data_source"), do: :data_source
  defp kind_atom("communication"), do: :communication
end
