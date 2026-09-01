defmodule Zaq.Contracts.Record.Provenance do
  @moduledoc """
  Authenticated provenance for data-source Records.

  Provenance proves that a Record and its permission projection were issued by
  ZAQ. It is not an authorization grant; callers must still use their trusted
  actor context for permission decisions.
  """

  alias Plug.Crypto.{KeyGenerator, MessageVerifier}
  alias Zaq.Contracts.Record
  alias Zaq.Helpers

  @salt "zaq.record.provenance"
  @version 1
  @payload_keys MapSet.new(["v", "claims"])
  @record_claim_keys [
    "record_id",
    "provider_record_id",
    "kind",
    "parent_id",
    "permissions"
  ]

  @type claims :: map()

  @spec issue(Record.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def issue(record, claims \\ %{}, opts \\ [])

  def issue(%Record{} = record, claims, opts) when is_map(claims) do
    payload = %{"v" => @version, "claims" => canonical_claims(record, claims)}

    case Jason.encode(payload) do
      {:ok, encoded} -> {:ok, MessageVerifier.sign(encoded, secret(opts))}
      {:error, _reason} -> {:error, :invalid_record_provenance}
    end
  end

  def issue(_record, _claims, _opts), do: {:error, :invalid_record_provenance}

  @spec seal(Record.t(), map(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def seal(%Record{} = record, claims \\ %{}, opts \\ []) do
    with {:ok, ref} <- issue(%{record | provenance_ref: nil}, claims, opts) do
      {:ok, %{record | provenance_ref: ref}}
    end
  end

  @spec verify(Record.t(), keyword()) :: {:ok, claims()} | {:error, term()}
  def verify(record, opts \\ [])

  def verify(%Record{provenance_ref: ref} = record, opts) when is_binary(ref) do
    with {:ok, encoded} <- verify_signature(ref, opts),
         {:ok, payload} <- Jason.decode(encoded),
         {:ok, claims} <- validate_payload(payload),
         :ok <- verify_claims(record, claims) do
      {:ok, claims}
    else
      :error -> {:error, :invalid_record_provenance}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(%Record{}, _opts), do: {:error, :missing_record_provenance}
  def verify(_record, _opts), do: {:error, :invalid_record_provenance}

  @spec canonical_claims(Record.t(), map()) :: map()
  def canonical_claims(%Record{} = record, claims \\ %{}) when is_map(claims) do
    claims
    |> json_safe_map()
    |> Map.merge(record_claims(record))
  end

  @spec permission_projection(nil | [Record.t() | map()]) :: map()
  def permission_projection(nil), do: %{"state" => "not_loaded", "entries" => nil}

  def permission_projection(permissions) when is_list(permissions) do
    entries =
      permissions
      |> Enum.map(&permission_entry/1)
      |> Enum.sort_by(&Jason.encode!/1)

    %{"state" => "loaded", "entries" => entries}
  end

  def permission_projection(_permissions), do: %{"state" => "invalid", "entries" => nil}

  defp verify_signature(ref, opts) do
    case MessageVerifier.verify(ref, secret(opts)) do
      {:ok, encoded} -> {:ok, encoded}
      :error -> {:error, :invalid_record_provenance}
    end
  end

  defp validate_payload(%{"v" => @version, "claims" => claims} = payload) when is_map(claims) do
    with :ok <- validate_payload_keys(payload) do
      {:ok, claims}
    end
  end

  defp validate_payload(%{"v" => _version}), do: {:error, :unsupported_record_provenance}
  defp validate_payload(_payload), do: {:error, :invalid_record_provenance}

  defp validate_payload_keys(payload) do
    keys = payload |> Map.keys() |> MapSet.new()

    if MapSet.equal?(keys, @payload_keys) do
      :ok
    else
      {:error, :invalid_record_provenance}
    end
  end

  defp verify_claims(%Record{} = record, claims) do
    expected =
      canonical_claims(%{record | provenance_ref: nil}, Map.drop(claims, record_claim_keys()))

    if claims == expected do
      :ok
    else
      {:error, :record_provenance_mismatch}
    end
  end

  defp record_claims(%Record{} = record) do
    %{
      "record_id" => json_safe_value(record.id),
      "provider_record_id" => provider_record_id(record),
      "kind" => json_safe_value(record.kind),
      "parent_id" => json_safe_value(record.parent_id),
      "permissions" => permission_projection(record.permissions)
    }
    |> reject_nil_values()
  end

  defp record_claim_keys, do: @record_claim_keys

  defp permission_entry(%Record{} = permission) do
    attrs = permission.attributes || %{}

    %{
      "permission_id" => first_present([permission.id, attr(attrs, "permission_id")]),
      "principal" => principal(attrs),
      "role" => first_present([attr(attrs, "role"), attr(attrs, "access_role")]),
      "rights" => rights(attrs),
      "inherited" => boolean_value(attr(attrs, "inherited") || attr(attrs, "inherited?")),
      "origin_resource_id" => attr(attrs, "origin_resource_id")
    }
    |> reject_nil_values()
  end

  defp permission_entry(%{} = permission) do
    permission
    |> record_from_permission_map()
    |> permission_entry()
  end

  defp permission_entry(other) do
    %{"invalid" => json_safe_value(other)}
  end

  defp provider_record_id(%Record{} = record) do
    first_present([
      attr(record.attributes || %{}, "provider_record_id"),
      record.id
    ])
  end

  defp record_from_permission_map(map) do
    %Record{
      id: string_key(map, "id"),
      kind: string_key(map, "kind") || :permission,
      name: string_key(map, "name"),
      permissions: string_key(map, "permissions"),
      attributes: string_key(map, "attributes") || %{}
    }
  end

  defp principal(attrs) do
    type = first_present([attr(attrs, "principal_type"), attr(attrs, "type")])

    key =
      first_present([
        attr(attrs, "principal_key"),
        attr(attrs, "principal_id"),
        attr(attrs, "target_id"),
        attr(attrs, "email"),
        attr(attrs, "emailAddress"),
        attr(attrs, "email_address"),
        attr(attrs, "domain")
      ])

    %{"type" => json_safe_value(type), "key" => normalize_principal_key(key)}
    |> reject_nil_values()
  end

  defp normalize_principal_key(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_principal_key(value), do: json_safe_value(value)

  defp rights(attrs) do
    attrs
    |> attr("access_rights")
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&json_safe_value/1)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&Helpers.blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp attr(map, key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp string_key(map, key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp first_present(values),
    do: Enum.find(values, &(not is_nil(&1) and &1 != "")) |> json_safe_value()

  defp boolean_value(nil), do: nil
  defp boolean_value(value) when is_boolean(value), do: value
  defp boolean_value("true"), do: true
  defp boolean_value("false"), do: false
  defp boolean_value(value), do: json_safe_value(value)

  defp json_safe_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), json_safe_value(value)} end)
    |> Map.new()
  end

  defp json_safe_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_safe_value(%Date{} = value), do: Date.to_iso8601(value)
  defp json_safe_value(%Time{} = value), do: Time.to_iso8601(value)
  defp json_safe_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe_value(value) when is_map(value), do: json_safe_map(value)
  defp json_safe_value(value) when is_list(value), do: Enum.map(value, &json_safe_value/1)
  defp json_safe_value(value), do: value

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp secret(opts) do
    key_base = Keyword.get(opts, :secret_key_base) || ZaqWeb.Endpoint.config(:secret_key_base)
    KeyGenerator.generate(key_base, @salt)
  end
end
