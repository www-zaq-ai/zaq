defmodule Zaq.Agent.Tools.Accounts.NotifyUsers do
  @moduledoc """
  Sends one notification to a list of BO users through the Engine notification center.

  Use `resources.query` first to select BO users, then pass its `resources` list
  as `users`. This action only reads each user's `id`; supplied emails or names
  are ignored and the Engine resolves canonical account emails before delivery.

  Example `resources.query` call for selecting users:

      %{
        mode: "query",
        resource_type: "user",
        query: "operations",
        filters: %{"role_id" => 3},
        fields: ["id", "username", "email"],
        limit: 100
      }

  User search covers `username`, `email`, and `portal_consent`. Exact filters are
  `role_id`, `must_change_password`, and `portal_consent`. The `user` resource is
  private, so normal actor permissions or an explicit machine/admin
  `skip_permissions: true` context are required. Query results are capped at 100;
  use pagination and call this action again for larger audiences.
  """

  @schema Zoi.object(%{
            users:
              Zoi.list(Zoi.map(),
                description:
                  "BO user resources to notify. Pass resources.query output; only each id is used."
              ),
            subject: Zoi.string(description: "Notification subject."),
            message: Zoi.string(description: "Notification body sent to every user.")
          })
          |> Zoi.refine({__MODULE__, :validate_input, []})

  @output_schema Zoi.object(%{
                   requested_count: Zoi.integer(description: "Number of input user entries."),
                   recipient_count: Zoi.integer(description: "Number of unique users attempted."),
                   sent_count: Zoi.integer(description: "Number of delivered notifications."),
                   skipped_count: Zoi.integer(description: "Number of skipped notifications."),
                   failed_count: Zoi.integer(description: "Number of failed notifications."),
                   results: Zoi.list(Zoi.map(), description: "Per-user delivery outcomes.")
                 })

  use Zaq.Engine.Workflows.Action,
    name: "notify_users",
    description:
      "Notify BO users selected with resources.query. Pass its user resources as users plus one subject and message; only user ids are trusted, then Engine relays through the notification center.",
    schema: @schema,
    output_schema: @output_schema

  alias Jido.Action.Tool, as: ActionTool
  alias Zaq.Event
  alias Zaq.MapUtils
  alias Zaq.NodeRouter

  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params) do
    {:ok, ActionTool.convert_params_using_schema(params, schema())}
  end

  def on_before_validate_params(params), do: {:ok, params}

  @doc false
  def validate_input(params, _opts \\ [])

  def validate_input(%{users: users, subject: subject, message: message}, _opts) do
    cond do
      users == [] ->
        {:error, "users must include at least one BO user"}

      blank?(subject) ->
        {:error, "subject must not be blank"}

      blank?(message) ->
        {:error, "message must not be blank"}

      not Enum.all?(users, &(is_integer(MapUtils.fetch(&1, :id)) and MapUtils.fetch(&1, :id) > 0)) ->
        {:error, "each user must include a positive integer id"}

      true ->
        :ok
    end
  end

  def validate_input(_params, _opts), do: {:error, "users, subject, and message are required"}

  @impl Jido.Action
  def run(%{users: users, subject: subject, message: message}, context) do
    user_ids = Enum.map(users, &MapUtils.fetch(&1, :id))
    node_router = Map.get(context, :node_router, NodeRouter)

    %{user_ids: user_ids, subject: subject, message: message}
    |> Event.new(:engine, opts: [action: :notify_users])
    |> node_router.dispatch()
    |> Map.get(:response)
    |> handle_response()
  end

  defp handle_response({:ok, result}) when is_map(result), do: {:ok, result}
  defp handle_response({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp handle_response({:error, reason}), do: {:error, inspect(reason)}
  defp handle_response(other), do: {:error, "notify_users_failed:#{inspect(other)}"}

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
