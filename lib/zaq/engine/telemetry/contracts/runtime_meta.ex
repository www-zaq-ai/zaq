defmodule Zaq.Engine.Telemetry.Contracts.RuntimeMeta do
  @moduledoc """
  Runtime-only metadata for telemetry visualizations.

  This struct is not meant for direct rendering and carries navigation and
  operational metadata such as links and internal flags.
  Supported by all BO telemetry cards/charts through their envelope structs.
  """

  @type t :: %__MODULE__{href: String.t() | nil, extra: map()}

  defstruct href: nil, extra: %{}

  @spec from_map(map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}

  def from_map(meta) when is_map(meta) do
    href = Map.get(meta, :href) || Map.get(meta, "href")

    %__MODULE__{
      href: href,
      extra: Map.drop(meta, [:href, "href"])
    }
  end

  def from_map(_), do: %__MODULE__{}
end
