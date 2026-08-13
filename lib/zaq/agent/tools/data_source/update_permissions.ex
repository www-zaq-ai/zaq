defmodule Zaq.Agent.Tools.DataSource.UpdatePermissions do
  @moduledoc """
  ReAct tool: grants access to a document or a folder on a datasource provider.

  Access is granted to a person, a team, or everyone. Naming a folder cascades the grant onto
  every document under it — a folder holds no permissions of its own — which is the same
  behaviour an operator gets from the BO ingestion page.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  @grant_types ["person", "team"]

  @grant_schema Zoi.object(%{
                  type:
                    Zoi.enum(@grant_types,
                      description: "Who the grant names: person or team."
                    ),
                  target_id:
                    Zoi.string(
                      description:
                        "Id of the person or team being granted access. A name or email is accepted and resolved; if it matches more than one, the call is refused and the candidates are returned so you can ask the user which one they mean."
                    ),
                  access_rights:
                    Zoi.list(Zoi.string(),
                      description:
                        "Rights to grant, such as read, write, update, or delete. Defaults to read."
                    )
                    |> Zoi.optional()
                })

  @schema Zoi.object(%{
            provider: Zoi.string(description: "Datasource provider key"),
            file_id:
              Zoi.string(
                description:
                  "Id of the document or folder to share, as returned by list_documents."
              )
              |> Zoi.optional(),
            path:
              Zoi.string(
                description: "Path of the document or folder to share, instead of file_id."
              )
              |> Zoi.optional(),
            volume:
              Zoi.string(description: "Optional volume the path sits on.")
              |> Zoi.optional(),
            grants:
              Zoi.list(@grant_schema,
                description: "People and teams to grant access to."
              )
              |> Zoi.optional(),
            public:
              Zoi.boolean(
                description:
                  "Set true to give everyone read access, false to withdraw it. Omit to leave current visibility unchanged."
              )
              |> Zoi.optional(),
            config_id:
              Zoi.string(description: "Optional scoped datasource config id")
              |> Zoi.optional()
          })
          |> Zoi.refine({__MODULE__, :validate_target, []})

  @output_schema Zoi.object(%{
                   records:
                     Zoi.any(description: "Resulting permission records after the grant")
                     |> Zoi.optional(),
                   stats:
                     Zoi.any(
                       description:
                         "Result counts, including applied_to: how many documents were written"
                     )
                     |> Zoi.optional()
                 })

  use Zaq.Engine.Workflows.Action,
    name: "update_permissions",
    description: """
    Grant a person, a team, or everyone access to a document or folder on a datasource provider.
    Naming a folder applies the grant to every document inside it.
    A grant target may be an id, a name, or an email; an ambiguous name is refused with the
    candidates listed, so ask the user which one they meant rather than guessing.
    Returns the permissions the record holds afterwards.
    """,
    schema: @schema,
    output_schema: @output_schema

  alias Zaq.Agent.Tools.Helpers.ChannelTool

  @doc false
  def validate_target(params, _opts \\ [])

  def validate_target(params, _opts) when is_map(params) do
    if present?(params, :file_id) or present?(params, :path) do
      :ok
    else
      {:error, "either file_id or path is required"}
    end
  end

  def validate_target(_params, _opts), do: {:error, "params must be an object"}

  defp present?(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> true
      _ -> false
    end
  end

  @impl Jido.Action
  def run(%{provider: provider} = params, context) do
    request =
      %{}
      |> ChannelTool.merge_optional(params, [
        :file_id,
        :path,
        :volume,
        :grants,
        :public,
        :config_id
      ])
      |> ChannelTool.wrap_request(provider)

    ChannelTool.dispatch(
      :data_source_update_permissions,
      request,
      context,
      "Data source permission update failed"
    )
  end
end
