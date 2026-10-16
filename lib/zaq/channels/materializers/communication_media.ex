defmodule Zaq.Channels.Materializers.CommunicationMedia do
  @moduledoc """
  Materializes communication-channel media through the existing Channels bridge route.

  Owns the versioned durable source metadata used to reconstruct lazy attachment
  Records. Source metadata is stored without runtime handles or media bytes.
  """

  @behaviour Zaq.Materialization.Handler

  alias Zaq.Channels.Events
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Events, as: EngineEvents
  alias Zaq.Events.TrustedContext
  alias Zaq.Helpers
  alias Zaq.MapUtils

  @type_key "communication_media"
  @locator_fields ~w(provider reference name mime_type media_kind size channel_config_id source_author_id source_channel_id source_message_id mailbox uid_validity uid section encoding disposition content_id)

  @spec issue(atom() | String.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def issue(provider, reference, attrs \\ %{}, opts \\ [])

  def issue(provider, reference, attrs, opts)
      when (is_atom(provider) or is_binary(provider)) and is_binary(reference) and is_map(attrs) do
    Zaq.Materialization.issue(
      @type_key,
      source_metadata(provider, reference, attrs)["locator"],
      opts
    )
  end

  def issue(_provider, _reference, _attrs, _opts), do: {:error, :invalid_materialization_handle}

  @doc "Returns JSON-safe durable source facts, using the same locator as handle issuance."
  @spec source_metadata(atom() | String.t(), String.t(), map()) :: map()
  def source_metadata(provider, reference, attrs) do
    locator =
      attrs
      |> Map.take(@locator_fields)
      |> Map.merge(%{"provider" => to_string(provider), "reference" => reference})
      |> drop_blank_values()

    %{"version" => 1, "type" => @type_key, "locator" => locator}
  end

  @doc """
  Reconstructs a lazy Record from trusted, authorized attachment source metadata.

  This internal operation never downloads bytes or accepts model-supplied locators.
  Canonical wrappers come only from Engine's authorized history projection; they
  preserve author provenance while binding redemption to current transcript access.
  """
  @spec hydrate(map(), map()) :: {:ok, Record.t()} | {:error, term()}
  def hydrate(
        %{descriptor: descriptor, transcript_id: transcript_id, message_id: message_id},
        context
      )
      when is_map(context) do
    scope = %{"version" => 1, "transcript_id" => transcript_id, "message_id" => message_id}

    with :ok <- validate_canonical_scope(scope) do
      hydrate_record(descriptor, context, scope)
    end
  end

  def hydrate(descriptor, context) when is_map(descriptor) and is_map(context),
    do: hydrate_record(descriptor, context, nil)

  def hydrate(_descriptor, _context), do: {:error, :invalid_materialization_source}

  defp hydrate_record(descriptor, context, scope) do
    metadata = Record.attachment_metadata(descriptor)

    with {:ok, locator} <- hydration_locator(metadata),
         :ok <- authorize_hydration(locator, context, scope),
         locator =
           if(is_nil(scope), do: locator, else: Map.put(locator, "canonical_attachment", scope)),
         {:ok, handle} <- Zaq.Materialization.issue(@type_key, locator) do
      {:ok,
       %Record{
         id: metadata["id"],
         kind: :file,
         name: metadata["name"],
         mime_type: metadata["mime_type"],
         size: metadata["size"],
         attributes: metadata["attributes"],
         materialization_handle: handle
       }}
    end
  end

  defp authorize_hydration(locator, context, nil), do: authorize(locator, context)
  defp authorize_hydration(_locator, _context, _scope), do: :ok

  defp hydration_locator(%{
         "id" => id,
         "kind" => "file",
         "attributes" => %{
           "materialization_source" => %{
             "version" => 1,
             "type" => @type_key,
             "locator" => locator
           }
         }
       })
       when is_map(locator) do
    with true <- Map.get(locator, "reference") == id,
         true <- valid_source_fields?(locator),
         {:ok, request} <- validate_locator(locator) do
      {:ok, request}
    else
      _ -> {:error, :invalid_materialization_source}
    end
  end

  defp hydration_locator(_metadata), do: {:error, :invalid_materialization_source}

  defp valid_source_fields?(locator) do
    required =
      ~w(provider reference channel_config_id source_author_id source_channel_id source_message_id)

    valid_source_config?(Map.get(locator, "channel_config_id")) and
      Enum.all?(required, &(Map.has_key?(locator, &1) and not blank?(string(locator, &1)))) and
      Enum.all?(locator, fn {key, value} ->
        key in @locator_fields and (is_binary(value) or is_integer(value))
      end)
  end

  defp valid_source_config?(id) when is_integer(id), do: id > 0

  defp valid_source_config?(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> true
      _ -> false
    end
  end

  defp valid_source_config?(_id), do: false

  @impl true
  def materialization_options, do: []

  @impl true
  def materialize(locator, context, options \\ %{})

  def materialize(locator, context, options),
    do: Zaq.Materialization.materialize_with_handler(__MODULE__, locator, context, options)

  @impl true
  def do_materialize(locator, context, options)

  def do_materialize(locator, context, options)
      when is_map(locator) and is_map(context) and is_map(options) do
    with {:ok, request} <- validate_locator(locator),
         :ok <- authorize_redemption(locator, request, context) do
      request
      |> Events.build_and_dispatch_materialize_record_event(
        TrustedContext.event_builder_opts(context,
          event_opts: communication_event_opts(context)
        )
      )
      |> Map.fetch!(:response)
    end
  end

  def do_materialize(_locator, _context, _options), do: {:error, :invalid_materialization_locator}

  defp authorize_redemption(locator, request, context) do
    case Map.fetch(locator, "canonical_attachment") do
      :error -> authorize(request, context)
      {:ok, scope} -> authorize_canonical(scope, request, context)
    end
  end

  defp validate_canonical_scope(
         %{"version" => 1, "transcript_id" => transcript_id, "message_id" => message_id} = scope
       )
       when map_size(scope) == 3 do
    with {:ok, ^transcript_id} <- Ecto.UUID.cast(transcript_id),
         {:ok, ^message_id} <- Ecto.UUID.cast(message_id) do
      :ok
    else
      _ -> {:error, :unauthorized_materialization_handle}
    end
  end

  defp validate_canonical_scope(_scope), do: {:error, :unauthorized_materialization_handle}

  defp authorize_canonical(scope, request, context) do
    with :ok <- validate_canonical_scope(scope) do
      scope["transcript_id"]
      |> EngineEvents.build_and_dispatch_canonical_message_event(
        scope["message_id"],
        TrustedContext.event_builder_opts(context)
      )
      |> authorize_canonical_response(scope, request)
    end
  end

  defp authorize_canonical_response(
         %{
           response:
             {:ok,
              %{transcript_id: transcript_id, message_id: message_id, attachments: attachments}}
         },
         scope,
         request
       ) do
    if transcript_id == scope["transcript_id"] and
         message_id == scope["message_id"] and
         matching_canonical_attachment?(attachments, request),
       do: :ok,
       else: {:error, :unauthorized_materialization_handle}
  end

  defp authorize_canonical_response(%{response: {:error, reason}}, _scope, _request)
       when reason in [:unauthorized, :not_found, :source_scope_mismatch, :invalid_request],
       do: {:error, :unauthorized_materialization_handle}

  defp authorize_canonical_response(_response, _scope, _request),
    do: {:error, :canonical_message_unavailable}

  defp matching_canonical_attachment?(attachments, request) when is_list(attachments) do
    case Enum.filter(attachments, &(is_map(&1) and Map.get(&1, "id") == request["reference"])) do
      [descriptor] -> hydration_locator(Record.attachment_metadata(descriptor)) == {:ok, request}
      _ -> false
    end
  end

  defp matching_canonical_attachment?(_attachments, _request), do: false

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
