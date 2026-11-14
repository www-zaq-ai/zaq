Code.require_file("../../scripts/lib/extension_proto.exs", __DIR__)

defmodule Zaq.Scripts.ExtensionProtoTest do
  use ExUnit.Case, async: true

  alias Zaq.Scripts.ExtensionProto

  @moduletag :protobuf

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "zaq-proto-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    schema = Path.join(root, "schema")
    output = Path.join(root, "bindings")
    File.mkdir_p!(schema)
    File.cp!("priv/proto/gateway.proto", Path.join(schema, "gateway.proto"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, schema: schema, output: output, opts: [schema_dir: schema, output_dir: output]}
  end

  test "generation is deterministic and clean checking does not write", %{
    opts: opts,
    output: output
  } do
    assert :ok = ExtensionProto.run(opts)
    original = contents(output)
    assert map_size(original) == 4
    assert :ok = ExtensionProto.run(Keyword.put(opts, :check, true))
    assert :ok = ExtensionProto.run(opts)
    assert contents(output) == original
  end

  test "checking detects edited, missing and obsolete generated files without writes", %{
    opts: opts,
    output: output
  } do
    ExtensionProto.run(opts)
    [first, second | _] = output |> contents() |> Map.keys() |> Enum.sort()
    File.write!(Path.join(output, first), "# edited\n", [:append])
    File.rm!(Path.join(output, second))
    File.cp!(Path.join(output, first), Path.join(output, "obsolete.pb.ex"))
    original = contents(output)

    assert_raise Mix.Error, ~r/stale/, fn ->
      ExtensionProto.run(Keyword.put(opts, :check, true))
    end

    assert contents(output) == original
    assert :ok = ExtensionProto.run(opts)
    refute File.exists?(Path.join(output, "obsolete.pb.ex"))
  end

  test "new RPCs, messages, nested types and imported types regenerate without a file allowlist",
       %{opts: opts, schema: schema, output: output} do
    ExtensionProto.run(opts)

    File.write!(Path.join(schema, "shared.proto"), """
    syntax = "proto3";
    package gateway.v1;
    message Details { enum Mode { UNKNOWN = 0; READY = 1; } Mode mode = 1; }
    """)

    File.write!(Path.join(schema, "gateway.proto"), """
    syntax = "proto3";
    package gateway.v1;
    import "shared.proto";
    service Gateway { rpc Health(HealthRequest) returns (HealthResponse); rpc Ready(HealthRequest) returns (Details); }
    message HealthRequest {}
    message HealthResponse { string status = 1; Details details = 2; }
    """)

    assert_raise Mix.Error, ~r/stale/, fn ->
      ExtensionProto.run(Keyword.put(opts, :check, true))
    end

    assert :ok = ExtensionProto.run(opts)
    generated = contents(output)
    assert map_size(generated) == 6
    assert generated["gateway/v1/gateway/service.pb.ex"] =~ ":Ready"
    assert generated["gateway/v1/health_response.pb.ex"] =~ "field(:details"
    assert :ok = ExtensionProto.run(Keyword.put(opts, :check, true))
  end

  test "invalid schemas cannot modify existing bindings", %{
    opts: opts,
    schema: schema,
    output: output
  } do
    ExtensionProto.run(opts)
    original = contents(output)
    File.write!(Path.join(schema, "gateway.proto"), "invalid protobuf")
    assert_raise Mix.Error, ~r/protoc failed/, fn -> ExtensionProto.run(opts) end
    assert contents(output) == original
  end

  test "unowned files are not overwritten or removed", %{opts: opts, output: output} do
    File.mkdir_p!(output)
    File.write!(Path.join(output, "handwritten.pb.ex"), "# user work\n")
    assert_raise Mix.Error, ~r/unowned/, fn -> ExtensionProto.run(opts) end
    assert File.read!(Path.join(output, "handwritten.pb.ex")) == "# user work\n"
  end

  test "missing and incompatible compilers fail with a useful diagnostic", %{
    opts: opts,
    root: root
  } do
    assert_raise Mix.Error, ~r/protoc.*not found/, fn ->
      ExtensionProto.run(Keyword.put(opts, :protoc, Path.join(root, "absent")))
    end

    compiler = Path.join(root, "wrong-protoc")
    File.write!(compiler, "#!/bin/sh\necho 'libprotoc 0.0'\n")
    File.chmod!(compiler, 0o700)

    version = "priv/proto/protoc.version" |> File.read!() |> String.trim()

    assert_raise Mix.Error, "Expected protoc #{version}, got: libprotoc 0.0", fn ->
      ExtensionProto.run(Keyword.put(opts, :protoc, compiler))
    end
  end

  test "an output symlink cannot redirect generation", %{opts: opts, output: output, root: root} do
    target = Path.join(root, "user-directory")
    File.mkdir!(target)
    File.ln_s!(target, output)
    assert_raise Mix.Error, ~r/unowned output path/, fn -> ExtensionProto.run(opts) end
    assert File.ls!(target) == []
  end

  defp contents(directory) do
    directory
    |> Path.join("**/*.pb.ex")
    |> Path.wildcard()
    |> Map.new(fn path -> {Path.relative_to(path, directory), File.read!(path)} end)
  end
end
