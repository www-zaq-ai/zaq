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
end
