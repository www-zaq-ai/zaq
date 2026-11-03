defmodule ZaqWeb.Live.BO.LabelEvents do
  @moduledoc "BO label event dispatch and safe presentation of operation failures."
  alias Zaq.{Event, NodeRouter}
  alias ZaqWeb.Live.BO.AI.BOActor

  @spec call(map(), atom(), map()) :: term()
  def call(user, action, request \\ %{}) do
    request
    |> Event.new(:ingestion,
      actor: BOActor.build(user),
      opts: [action: action, confidential: true]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end

  @doc "Remove a selected label using the shared editor projection and versioned mutation."
  @spec remove(map(), map(), integer()) :: term()
  def remove(user, resource, label_id) do
    with {:ok, editor} <- call(user, :get_resource_labels, %{resource: resource}),
         true <- editor.editable?,
         %{selected: true} = label <- Enum.find(editor.labels, &(&1.id == label_id)) do
      call(user, :edit_resource_labels, %{
        resource: resource,
        edits: [
          %{label_id: label_id, operation: "remove", expected_version: label.expected_version}
        ]
      })
    else
      {:error, _} = error -> error
      false -> {:error, :forbidden}
      _ -> {:error, :stale}
    end
  end

  @spec error_message(term()) :: String.t()
  def error_message(:stale),
    do: "Labels changed while you were editing. Reload to review the latest labels."

  def error_message(:target_in_use),
    do: "This resource type still has label assignments and cannot be removed."

  def error_message(:invalid_value), do: "Label values must be text of at most 200 characters."

  def error_message(:invalid_targets), do: "Choose at least one resource type."
  def error_message(:automation_unavailable), do: "Automatic labeling is not available yet."
  def error_message(:not_found), do: "This resource is no longer available."

  def error_message(reason) when reason in [:unauthorized, :forbidden],
    do: "You do not have permission to make this change."

  def error_message(_), do: "Labels could not be saved. Please try again."
end
