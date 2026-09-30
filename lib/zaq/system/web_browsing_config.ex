defmodule Zaq.System.WebBrowsingConfig do
  @moduledoc """
  Validated global web browsing policy and screenshot destination settings.

  An empty domain list allows unrestricted browsing. A destination is optional,
  but when provided it must identify a specific data-source configuration and folder.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :allowed_domains, :string, default: ""
    field :provider, :string
    field :config_id, :integer
    field :scope_id, :string
    field :folder_id, :string
    field :folder_path, :string
  end

  @type t :: %__MODULE__{}
  @fields ~w(allowed_domains provider config_id scope_id folder_id folder_path)a

  @doc "Validates global settings from persisted strings or BO form attributes."
  def changeset(config, attrs) when is_map(attrs) and not is_struct(attrs) do
    attrs = Enum.reduce(@fields, %{}, &copy_field(&1, &2, attrs))

    config
    |> cast(attrs, @fields)
    |> normalize_allowed_domains()
    |> validate_destination()
  end

  def changeset(config, _attrs), do: config |> change() |> add_error(:base, "invalid settings")

  defp copy_field(field, acc, attrs) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> Map.put(acc, field, value)
      :error -> copy_string_field(field, acc, attrs)
    end
  end

  defp copy_string_field(field, acc, attrs) do
    case Map.fetch(attrs, Atom.to_string(field)) do
      {:ok, value} -> Map.put(acc, field, value)
      :error -> acc
    end
  end

  @doc "Canonicalizes a comma-separated list of exact ASCII DNS hostnames."
  @spec normalize_domains(term()) :: {:ok, String.t()} | {:error, :invalid_domains}
  def normalize_domains(value) when is_binary(value) do
    domains = value |> String.split(",") |> Enum.map(&String.downcase(String.trim(&1)))

    if Enum.all?(domains, &valid_domain?/1) do
      {:ok, domains |> Enum.reject(&(&1 == "")) |> Enum.uniq() |> Enum.join(",")}
    else
      {:error, :invalid_domains}
    end
  end

  def normalize_domains(_value), do: {:error, :invalid_domains}

  defp valid_domain?(""), do: true

  defp valid_domain?(domain) when byte_size(domain) <= 253 do
    domain
    |> String.split(".")
    |> Enum.all?(fn label ->
      byte_size(label) in 1..63 and
        Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, label)
    end)
  end

  defp valid_domain?(_), do: false

  defp normalize_allowed_domains(changeset) do
    case normalize_domains(get_field(changeset, :allowed_domains) || "") do
      {:ok, value} -> put_change(changeset, :allowed_domains, value)
      {:error, _} -> add_error(changeset, :allowed_domains, "enter comma-separated hostnames")
    end
  end

  defp validate_destination(changeset) do
    provider = get_field(changeset, :provider)
    config_id = get_field(changeset, :config_id)
    folder_id = get_field(changeset, :folder_id)
    folder_path = get_field(changeset, :folder_path)
    scope_id = get_field(changeset, :scope_id)

    if Enum.any?([provider, config_id, folder_id, folder_path, scope_id], &(&1 not in [nil, ""])) do
      changeset
      |> validate_required([:provider, :config_id])
      |> validate_number(:config_id, greater_than: 0)
      |> require_folder(folder_id, folder_path)
    else
      changeset
    end
  end

  defp require_folder(changeset, folder_id, folder_path)
       when folder_id in [nil, ""] and folder_path in [nil, ""],
       do: add_error(changeset, :folder_id, "choose a folder")

  defp require_folder(changeset, _folder_id, _folder_path), do: changeset
end
