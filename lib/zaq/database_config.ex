defmodule Zaq.DatabaseConfig do
  @moduledoc """
  Production Repo connection configuration shared by release migrations and startup.
  Ecto owns URL decoding; this boundary validates TLS and keeps parser errors secret-safe.
  Container URL construction and libpq provisioning remain in the bootstrap scripts.
  """

  @doc """
  Parses an application URL, optionally using a PEM CA bundle for verified TLS.

  The CA file requires `ssl=true`. Without a file, Postgrex uses system trust and
  verifies the server hostname. Invalid configuration raises without URL values.
  """
  def from_url!(url, ca_file) do
    config = parse_url!(url)

    case {config[:ssl], ca_file} do
      {_, ca} when ca in [nil, ""] ->
        config

      {true, ca} ->
        unless File.regular?(ca) and match?({:ok, _}, File.read(ca)) do
          raise ArgumentError, "ZAQ_DATABASE_SSL_CA_CERT_FILE must be a readable PEM CA file"
        end

        Keyword.put(config, :ssl,
          verify: :verify_peer,
          cacertfile: ca,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        )

      _ ->
        raise ArgumentError, "ZAQ_DATABASE_SSL_CA_CERT_FILE requires DATABASE_URL ssl=true"
    end
  end

  defp parse_url!(url) do
    query = URI.parse(url).query || ""
    options = Enum.to_list(URI.query_decoder(query))
    tls = for {"ssl", value} <- options, do: value

    if tls not in [[], ["true"], ["false"]] or
         Enum.any?(options, fn {key, _} -> String.starts_with?(key, "ssl") and key != "ssl" end) do
      raise ArgumentError
    end

    Ecto.Repo.Supervisor.parse_url(url)
  rescue
    _ ->
      reraise ArgumentError,
              "Invalid DATABASE_URL; use ssl=true or ssl=false for application TLS",
              __STACKTRACE__
  end
end
