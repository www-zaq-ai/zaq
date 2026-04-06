defmodule Zaq.Channels.SmtpHelpers do
  @moduledoc false

  @setting_atom_keys %{
    "relay" => :relay,
    "port" => :port,
    "transport_mode" => :transport_mode,
    "tls" => :tls,
    "tls_verify" => :tls_verify,
    "ca_cert_path" => :ca_cert_path,
    "username" => :username,
    "password" => :password,
    "from_email" => :from_email,
    "from_name" => :from_name
  }

  @doc "Looks up a SMTP settings key by string name, falling back to its atom equivalent."
  def map_get(map, key) when is_map(map) do
    atom_key = Map.get(@setting_atom_keys, key)
    if atom_key, do: Map.get(map, key) || Map.get(map, atom_key), else: Map.get(map, key)
  end
end
