defmodule ZaqWeb.Live.BO.System.SystemConfig.AICredentialEventsTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Live.BO.System.SystemConfig.AICredentialEvents

  test "with_provider_endpoint/3 updates endpoint when provider changes" do
    params = %{"provider" => "openai"}

    result =
      AICredentialEvents.with_provider_endpoint(params, "anthropic", fn provider ->
        "https://#{provider}.example"
      end)

    assert result["endpoint"] == "https://openai.example"
  end

  test "save/6 uses update flow for edit action" do
    result =
      AICredentialEvents.save(
        :edit,
        10,
        %{"name" => "n"},
        fn 10 -> %{id: 10} end,
        fn credential, params -> {:ok, {credential.id, params["name"]}} end,
        fn _params -> :should_not_be_called end
      )

    assert result == {:ok, {10, "n"}}
  end

  test "save/6 uses create flow for non-edit action" do
    result =
      AICredentialEvents.save(
        :new,
        nil,
        %{"name" => "n"},
        fn _ -> :should_not_be_called end,
        fn _, _ -> :should_not_be_called end,
        fn params -> {:ok, params["name"]} end
      )

    assert result == {:ok, "n"}
  end
end
