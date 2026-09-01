defmodule Zaq.System.HttpCredentialProvider do
  @moduledoc """
  BO-managed provider definition for rendering Auth Credentials into HTTP requests.

  Providers own non-secret rendering rules: authentication kind, placement,
  parameter name, destination host patterns, and enabled state. Secret material
  stays in `Zaq.Engine.Connect.Credential`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @auth_kinds ~w(bearer basic api_key custom)
  @placements ~w(authorization header query)

  schema "http_credential_providers" do
    field :name, :string
    field :auth_kind, :string
    field :placement, :string
    field :parameter_name, :string
    field :host_patterns, {:array, :string}, default: []
    field :enabled, :boolean, default: true
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "Validates a dynamic HTTP credential provider."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :name,
      :auth_kind,
      :placement,
      :parameter_name,
      :host_patterns,
      :enabled,
      :metadata
    ])
    |> validate_required([:name, :auth_kind, :placement, :host_patterns])
    |> validate_length(:name, min: 2, max: 255)
    |> validate_inclusion(:auth_kind, @auth_kinds)
    |> validate_inclusion(:placement, @placements)
    |> normalize_parameter_name()
    |> normalize_host_patterns()
    |> validate_parameter_name()
    |> validate_host_patterns()
    |> unique_constraint(:name)
  end

  defp normalize_parameter_name(changeset) do
    update_change(changeset, :parameter_name, fn
      nil -> nil
      value -> value |> to_string() |> String.trim() |> String.downcase()
    end)
  end

  defp normalize_host_patterns(changeset) do
    update_change(changeset, :host_patterns, fn patterns ->
      patterns
      |> List.wrap()
      |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_parameter_name(changeset) do
    placement = get_field(changeset, :placement)
    name = get_field(changeset, :parameter_name)

    cond do
      placement in ["header", "query"] and name in [nil, ""] ->
        add_error(changeset, :parameter_name, "is required for header and query placement")

      placement == "authorization" and name not in [nil, ""] ->
        add_error(changeset, :parameter_name, "must be blank for authorization placement")

      is_binary(name) and String.contains?(name, ["\r", "\n"]) ->
        add_error(changeset, :parameter_name, "must not contain line breaks")

      placement == "header" and name in ["authorization", "proxy-authorization", "host"] ->
        add_error(changeset, :parameter_name, "is a reserved header")

      true ->
        changeset
    end
  end

  defp validate_host_patterns(changeset) do
    validate_change(changeset, :host_patterns, fn :host_patterns, patterns ->
      invalid = Enum.reject(patterns, &valid_host_pattern?/1)
      if invalid == [], do: [], else: [host_patterns: "contains invalid host patterns"]
    end)
  end

  defp valid_host_pattern?("." <> host), do: valid_hostname?(host)
  defp valid_host_pattern?(host), do: valid_hostname?(host)

  defp valid_hostname?(host) do
    String.match?(host, ~r/^[a-z0-9][a-z0-9.-]*[a-z0-9]$/) and not String.contains?(host, "..")
  end
end
