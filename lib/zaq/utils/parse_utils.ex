defmodule Zaq.Utils.ParseUtils do
  @moduledoc false

  @doc "Parses a string to an integer, returning `default` on nil, empty string, or parse failure."
  def parse_int(nil, default), do: default
  def parse_int("", default), do: default

  def parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end
end
