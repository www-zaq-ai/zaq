defmodule Zaq.Agent.Tools.DataSource.AttachDocuments do
  @moduledoc """
  Selects validated Records for the active request's final response.

  Selection does not deliver, materialize, or delete documents. Signed data-source
  Records reuse GetDocument for current authorized metadata; other signed Records
  reuse Record authorization. This Action owns selection rules through RequestEffects
  callbacks; the shared handler serializes commands before trace/history projection. Standalone and workflow
  callers require the same trusted active runtime context.
  """

  alias Jido.Action.Tool
  alias Zaq.Agent.RequestEffects

  @behaviour RequestEffects
  alias Zaq.Accounts.Person
  alias Zaq.Agent.Tools.DataSource.GetDocument
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Authorization
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Identity.ActorNormalizer

  use Zaq.Engine.Workflows.Action,
    name: "attach_documents",
    description: """
    Select loaded document Records for this response. add deduplicates, remove
    deselects without deleting sources, replace sets the exact selection (empty
    clears it). Selection is not delivery; files are sent only after a successful
    final answer. Pass complete Records returned by document tools.
    """,
    schema:
      Zoi.object(%{
        operation: Zoi.enum(["add", "remove", "replace"]),
        records: Zoi.list(Record.zoi_type(), max_length: 100)
      }),
    output_schema: Zoi.object(%{records: Zoi.list(Record.zoi_type())})

  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params),
    do: {:ok, Tool.convert_params_using_schema(params, schema())}

  def on_before_validate_params(params), do: {:ok, params}

  @impl Jido.Action
  def run(%{operation: operation, records: records}, context) do
    with {:ok, records} <- authorize(records, context),
         {:ok, effect} <-
           RequestEffects.command(context, __MODULE__, %{operation: operation, records: records}) do
      {:ok, %{records: records}, [effect]}
    end
  end

  @impl RequestEffects
  def init_request_effect, do: []

  @impl RequestEffects
  def reduce_request_effect(selected, %{operation: "add", records: records}),
    do: {:ok, Enum.uniq_by(selected ++ records, &selection_identity/1)}

  def reduce_request_effect(_selected, %{operation: "replace", records: records}),
    do: {:ok, Enum.uniq_by(records, &selection_identity/1)}

  def reduce_request_effect(selected, %{operation: "remove", records: records}) do
    removed = MapSet.new(records, &selection_identity/1)
    {:ok, Enum.reject(selected, &MapSet.member?(removed, selection_identity(&1)))}
  end

  defp selection_identity(%Record{} = record) do
    {:ok, claims} = Provenance.verify(record)
    {claims["provider"], claims["config_id"], claims["provider_record_id"]}
  end

  defp authorize(records, context) do
    actor = Map.get(context, :actor)
    bypass? = Map.get(context, :skip_permissions) == true

    cond do
      not bypass? and not identified?(actor) -> {:error, :unauthorized}
      Enum.any?(records, &(&1.kind != :file)) -> {:error, :expected_document_records}
      bypass? -> {:ok, records}
      true -> authorize_records(records, context)
    end
  end

  defp authorize_records(records, context) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, validated} ->
      case authorized_record(record, context) do
        {:ok, record} -> {:cont, {:ok, [record | validated]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp authorized_record(record, context) do
    case Provenance.verify(record) do
      {:ok, %{"provider" => provider} = claims} when is_binary(provider) ->
        params = %{provider: provider, document_id: claims["provider_record_id"]}

        params =
          if claims["config_id"],
            do: Map.put(params, :config_id, to_string(claims["config_id"])),
            else: params

        case Jido.Exec.run(GetDocument, params, context) do
          {:ok, %{record: %Record{kind: :file} = current}} -> {:ok, current}
          _ -> {:error, :unauthorized}
        end

      {:ok, _claims} ->
        if Authorization.can?(Map.get(context, :actor), record, :read),
          do: {:ok, record},
          else: {:error, :unauthorized}

      {:error, _} ->
        {:error, :invalid_record}
    end
  end

  defp identified?(%Person{id: id}), do: is_integer(id) and id > 0
  defp identified?(actor), do: not is_nil(ActorNormalizer.person_id(actor))
end
