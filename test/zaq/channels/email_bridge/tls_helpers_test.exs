defmodule Zaq.Channels.EmailBridge.TlsHelpersTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.EmailBridge.TlsHelpers

  defp with_public_key_stub(source, fun) do
    {:public_key, original_binary, original_path} = :code.get_object_code(:public_key)

    stub_dir =
      Path.join([
        System.tmp_dir!(),
        "zaq_public_key_stub",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    File.mkdir_p!(stub_dir)
    stub_path = Path.join(stub_dir, "public_key.erl")
    File.write!(stub_path, source)

    {:ok, :public_key, stub_binary} = :compile.file(String.to_charlist(stub_path), [:binary])

    :code.purge(:public_key)
    :code.delete(:public_key)
    {:module, :public_key} = :code.load_binary(:public_key, ~c"public_key.beam", stub_binary)

    on_exit(fn ->
      :code.purge(:public_key)
      :code.delete(:public_key)
      {:module, :public_key} = :code.load_binary(:public_key, original_path, original_binary)
      File.rm_rf!(stub_dir)
    end)

    fun.()
  end

  test "default_cacerts returns DER binaries from public_key" do
    with_public_key_stub(
      ~S"""
      -module(public_key).
      -export([cacerts_get/0]).
      cacerts_get() -> [{cert, <<1,2,3>>, ignored}, <<4,5,6>>, ignored].
      """,
      fn ->
        assert TlsHelpers.default_cacerts() == [<<1, 2, 3>>, <<4, 5, 6>>]
      end
    )
  end

  test "default_cacerts returns empty list when public_key raises" do
    with_public_key_stub(
      ~S"""
      -module(public_key).
      -export([cacerts_get/0]).
      cacerts_get() -> error(unavailable).
      """,
      fn ->
        assert TlsHelpers.default_cacerts() == []
      end
    )
  end
end
