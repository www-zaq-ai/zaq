defmodule Zaq.System.OutboundHttpPolicy do
  @moduledoc """
  Embedded schema for globally managed outbound HTTP security policy.

  The policy is intentionally fail-closed: the request action is disabled by
  default, private/special-use ranges are blocked, redirects are disabled, and
  only safe methods are enabled until an admin broadens the policy.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @safe_methods ~w(GET HEAD OPTIONS)
  @supported_methods ~w(GET HEAD OPTIONS POST PUT PATCH DELETE QUERY)

  @type t :: %__MODULE__{}

  embedded_schema do
    field :enabled, :boolean, default: false
    field :block_loopback, :boolean, default: true
    field :block_private_networks, :boolean, default: true
    field :block_link_local, :boolean, default: true
    field :block_cloud_metadata, :boolean, default: true
    field :block_carrier_grade_nat, :boolean, default: true
    field :block_multicast, :boolean, default: true
    field :block_unspecified, :boolean, default: true
    field :block_reserved, :boolean, default: true
    field :block_ipv6_unique_local, :boolean, default: true
    field :blacklisted_hosts, {:array, :string}, default: []
    field :blacklisted_ips, {:array, :string}, default: []
    field :blacklisted_cidrs, {:array, :string}, default: []
    field :allowed_methods, {:array, :string}, default: @safe_methods
    field :allowed_ports, {:array, :integer}, default: []
    field :max_timeout_ms, :integer, default: 30_000
    field :max_response_bytes, :integer, default: 100_000
    field :follow_redirects, :boolean, default: false
  end

  @doc "Returns the complete set of methods the policy can allow."
  @spec supported_methods() :: [String.t()]
  def supported_methods, do: @supported_methods

  @doc "Returns the safe default method set."
  @spec safe_methods() :: [String.t()]
  def safe_methods, do: @safe_methods

  @doc "Validates outbound HTTP policy settings."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [
      :enabled,
      :block_loopback,
      :block_private_networks,
      :block_link_local,
      :block_cloud_metadata,
      :block_carrier_grade_nat,
      :block_multicast,
      :block_unspecified,
      :block_reserved,
      :block_ipv6_unique_local,
      :blacklisted_hosts,
      :blacklisted_ips,
      :blacklisted_cidrs,
      :allowed_methods,
      :allowed_ports,
      :max_timeout_ms,
      :max_response_bytes,
      :follow_redirects
    ])
    |> normalize_allowed_methods()
    |> validate_subset(:allowed_methods, @supported_methods)
    |> validate_length(:allowed_methods, min: 1)
    |> validate_number(:max_timeout_ms, greater_than: 0, less_than_or_equal_to: 120_000)
    |> validate_number(:max_response_bytes, greater_than: 0, less_than_or_equal_to: 10_000_000)
    |> validate_allowed_ports()
    # Redirect targets must repeat the full destination validation before this can be configurable.
    |> put_change(:follow_redirects, false)
    |> normalize_string_list(:blacklisted_hosts)
    |> normalize_string_list(:blacklisted_ips)
    |> normalize_string_list(:blacklisted_cidrs)
  end

  defp normalize_allowed_methods(changeset) do
    update_change(changeset, :allowed_methods, fn methods ->
      methods
      |> List.wrap()
      |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.upcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end)
  end

  defp validate_allowed_ports(changeset) do
    changeset
    |> update_change(:allowed_ports, &Enum.uniq/1)
    |> validate_change(:allowed_ports, fn :allowed_ports, ports ->
      invalid =
        ports
        |> List.wrap()
        |> Enum.reject(&(is_integer(&1) and &1 >= 1 and &1 <= 65_535))

      if invalid == [], do: [], else: [allowed_ports: "must contain ports from 1 to 65535"]
    end)
  end

  defp normalize_string_list(changeset, field) do
    update_change(changeset, field, fn values ->
      values
      |> List.wrap()
      |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end)
  end
end
