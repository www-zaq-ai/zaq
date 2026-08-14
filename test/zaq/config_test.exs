defmodule Zaq.ConfigTest do
  use ExUnit.Case, async: true

  defmodule StubConfig do
    def get(:zaq, :channels, _default) do
      %{google_drive: %{bridge: Zaq.ConfigTest.StubBridge}}
    end
  end

  defmodule StubConfigWithOpts do
    def get(:zaq, :channels, _default, opts) do
      Keyword.fetch!(opts, :channels)
    end
  end

  defmodule StubConfigWithoutGet do
  end

  defmodule StubBridge do
  end

  test "get/4 delegates to injected config module" do
    assert Zaq.Config.get(:zaq, :channels, %{}, config: StubConfig) == %{
             google_drive: %{bridge: StubBridge}
           }
  end

  test "get/4 delegates to injected config module with opts when supported" do
    assert Zaq.Config.get(:zaq, :channels, %{},
             config: StubConfigWithOpts,
             channels: %{google_drive: %{bridge: StubBridge}}
           ) == %{google_drive: %{bridge: StubBridge}}
  end

  test "get/4 falls back to application env when injected config is nil" do
    expected = %{source: :application_env}
    Application.put_env(:zaq, :config_nil_test_key, expected)

    on_exit(fn ->
      Application.delete_env(:zaq, :config_nil_test_key)
    end)

    assert Zaq.Config.get(:zaq, :config_nil_test_key, :default, config: nil) == expected
  end

  test "get/4 falls back to application env when injected atom module has no get callback" do
    expected = %{source: :fallback_for_missing_callback}
    Application.put_env(:zaq, :config_missing_callback_test_key, expected)

    on_exit(fn ->
      Application.delete_env(:zaq, :config_missing_callback_test_key)
    end)

    assert Zaq.Config.get(:zaq, :config_missing_callback_test_key, :default,
             config: StubConfigWithoutGet
           ) == expected
  end

  test "get/4 falls back to application env when injected config is not an atom" do
    expected = %{source: :fallback_for_invalid_config}
    Application.put_env(:zaq, :config_invalid_module_test_key, expected)

    on_exit(fn ->
      Application.delete_env(:zaq, :config_invalid_module_test_key)
    end)

    assert Zaq.Config.get(:zaq, :config_invalid_module_test_key, :default,
             config: %{not: :a_module}
           ) == expected
  end
end
