defmodule Zaq.Engine.Extension.Rpc.Gateway.V1.HealthResponse do
  @moduledoc false

  use Protobuf,
    full_name: "gateway.v1.HealthResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :status, 1, type: :string
end
