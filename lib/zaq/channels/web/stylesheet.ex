defmodule Zaq.Channels.Web.Stylesheet do
  @moduledoc """
  Pure validation of instance-scoped widget stylesheet URLs.

  Only absolute HTTP(S) URLs are supported. The browser adapter loads the
  resource; ZAQ neither fetches it nor persists its contents or URL.
  """

  @doc "Validates an optional remote stylesheet URL without fetching it."
  @spec validate(term()) :: :ok | {:error, {:invalid_field, :stylesheet_url}}
  def validate(nil), do: :ok

  def validate(url) when is_binary(url) and byte_size(url) <= 2_048 do
    with true <- String.valid?(url),
         false <- Regex.match?(~r/[\s\\\x00-\x1f\x7f]/u, url),
         {:ok, uri} <- URI.new(url),
         true <- uri.scheme in ["http", "https"],
         true <- is_binary(uri.host) and uri.host != "",
         false <- String.contains?(uri.host, "*"),
         true <- is_nil(uri.userinfo),
         true <- is_integer(uri.port) and uri.port in 1..65_535 do
      :ok
    else
      _ -> invalid()
    end
  rescue
    ArgumentError -> invalid()
  end

  def validate(_url), do: invalid()

  defp invalid, do: {:error, {:invalid_field, :stylesheet_url}}
end
