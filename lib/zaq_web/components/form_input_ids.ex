defmodule ZaqWeb.Components.FormInputIds do
  @moduledoc false

  @spec secret_input_id(term()) :: String.t()
  def secret_input_id(nil), do: "secret-input"

  def secret_input_id(name) when is_binary(name) do
    "secret-" <> String.replace(name, ~r/[^a-zA-Z0-9_-]+/, "-")
  end

  def secret_input_id(name), do: "secret-#{name}"
end
