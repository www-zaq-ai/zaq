defmodule Zaq.Channels.Materializers.CommunicationMedia do
  @moduledoc """
  Materializes communication-channel media through the existing Channels bridge route.
  """

  @behaviour Zaq.Materialization.Handler

  alias Zaq.Channels.Events
  alias Zaq.Helpers
  alias Zaq.MapUtils

  @type_key "communication_media"
  @locator_fields ~w(provider reference name mime_type media_kind size channel_config_id source_author_id source_channel_id source_message_id mailbox uid_validity uid section encoding disposition content_id)
  @option_fields []

  @spec issue(atom() | String.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def issue(provider, reference, attrs \\ %{}, opts \\ [])

  def issue(provider, reference, attrs, opts)
      when (is_atom(provider) or is_binary(provider)) and is_binary(reference) and is_map(attrs) do
    locator =
      attrs
      |> Map.take(@locator_fields)
      |> Map.merge(%{"provider" => to_string(provider), "reference" => reference})
      |> drop_blank_values()

    Zaq.Materialization.issue(@type_key, locator, opts)
  end

  def issue(_provider, _reference, _attrs, _opts), do: {:error, :invalid_materialization_handle}

  @impl true
  def materialize(locator, context, options \\ %{})

  def materialize(locator, context, options)
      when is_map(locator) and is_map(context) and is_map(options) do
    with {:ok, request} <- validate_locator(locator),
         :ok <- validate_options(options),
         :ok <- authorize(request, context) do
      request
      |> Events.build_and_dispatch_materialize_record_event(
        node_router_opts(context) ++
          [
            actor: actor(context),
            event_opts: communication_event_opts(context)
          ]
      )
      |> Map.fetch!(:response)
    end
  end

  def materialize(_locator, _context, _options), do: {:error, :invalid_materialization_locator}

  defp validate_locator(locator) do
    provider = string(locator, "provider")
    reference = string(locator, "reference")

    cond do
      blank?(provider) ->
        {:error, :invalid_materialization_locator}

      blank?(reference) ->
        {:error, :invalid_materialization_locator}

      true ->
        request =
          locator
          |> Map.take(@locator_fields)
          |> Map.put("provider", provider)
          |> Map.put("reference", reference)
          |> drop_blank_values()

        {:ok, request}
    end
  end

  defp validate_options(options) do
    case Map.keys(options) -- @option_fields do
      [] -> :ok
      _unknown -> {:error, :invalid_materialization_options}
    end
  end

  defp authorize(_request, %{skip_permissions: true}), do: :ok

  defp authorize(request, context) do
    expected = normalize(Map.get(request, "source_author_id"))
    actual = actor_id(context) |> normalize()

    if expected != "" and expected == actual,
      do: :ok,
      else: {:error, :unauthorized_materialization_handle}
  end

  defp actor_id(%{actor: actor}) when is_map(actor), do: MapUtils.fetch(actor, :id)

  defp actor_id(%{incoming: incoming}) when is_map(incoming),
    do: MapUtils.fetch(incoming, :author_id)

  defp actor_id(_context), do: nil

  defp communication_event_opts(context) do
    [materialization_verified: true]
    |> maybe_put_communication_bridge_module(Map.get(context, :communication_bridge_module))
  end

  defp maybe_put_communication_bridge_module(opts, nil), do: opts

  defp maybe_put_communication_bridge_module(opts, module),
    do: Keyword.put(opts, :communication_bridge_module, module)

  defp node_router_opts(context) do
    node_router = Map.get(context, :node_router)
    if is_nil(node_router), do: [], else: [node_router: node_router]
  end

  defp actor(context), do: MapUtils.fetch(context, :actor)
  defp string(map, key), do: string_value(Map.get(map, key))
  defp string_value(value) when is_binary(value), do: value
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(_value), do: nil
  defp blank?(value), do: !is_binary(value) or Helpers.blank?(value)
  defp normalize(nil), do: ""
  defp normalize(value), do: to_string(value)
  defp drop_blank_values(map), do: Map.reject(map, fn {_key, value} -> Helpers.blank?(value) end)
end
