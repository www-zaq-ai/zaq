defmodule Zaq.ConnectorConfig.LiveUpdatesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.ConnectorConfig.LiveUpdates

  test "absent settings use defaults but malformed stored policies fail closed" do
    assert {:ok, policy} = LiveUpdates.from_settings(%{})
    assert policy == LiveUpdates.defaults()
    assert policy["min_interval_ms"] == 100

    assert Map.keys(policy["triggers"]) |> Enum.sort() ==
             ~w(reasoning stream_delta tool_call)

    for value <- [nil, [], false, "", 1] do
      assert {:error, _errors} = LiveUpdates.from_settings(%{"live_updates" => value})
    end

    assert {:error, _errors} = LiveUpdates.from_settings(nil)
  end

  test "partial policies preserve false and fill only absent values" do
    assert {:ok, policy} =
             LiveUpdates.normalize(%{
               "enabled" => false,
               "triggers" => %{"tool_call" => false}
             })

    refute policy["enabled"]
    refute policy["triggers"]["tool_call"]
    assert policy["triggers"]["reasoning"]
    assert policy["throttle_enabled"]
  end

  test "form normalization accepts only known boolean and integer representations" do
    assert {:ok, policy} =
             LiveUpdates.normalize_form(%{
               "enabled" => "false",
               "throttle_enabled" => "true",
               "min_interval_ms" => "250",
               "triggers" => %{"tool_call" => "false"}
             })

    refute policy["enabled"]
    assert policy["throttle_enabled"]
    assert policy["min_interval_ms"] == 250
    refute policy["triggers"]["tool_call"]
    assert {:error, _} = LiveUpdates.normalize(%{"enabled" => "false"})
    assert {:error, _} = LiveUpdates.normalize_form(%{"enabled" => "anything"})
    assert {:error, _} = LiveUpdates.normalize_form(%{"min_interval_ms" => "100ms"})
  end

  test "closed schema rejects status, secrets, atom keys and invalid preferences even when disabled" do
    for policy <- [
          %{"status" => true},
          %{"token" => "not-a-policy-field"},
          %{enabled: true},
          %{"triggers" => %{"status" => true}},
          %{"triggers" => nil},
          %{"enabled" => nil},
          %{"enabled" => false, "min_interval_ms" => 0},
          %{"throttle_enabled" => false, "min_interval_ms" => -1},
          %{"min_interval_ms" => 1.5}
        ] do
      assert {:error, errors} = LiveUpdates.normalize(policy)
      assert is_map(errors)
      refute Enum.empty?(errors)
    end
  end

  property "all toggle combinations retain preferences and round trip through JSON" do
    check all(
            enabled <- boolean(),
            throttled <- boolean(),
            answer <- boolean(),
            reasoning <- boolean(),
            tool <- boolean(),
            interval <- positive_integer()
          ) do
      policy = %{
        "enabled" => enabled,
        "throttle_enabled" => throttled,
        "min_interval_ms" => interval,
        "triggers" => %{
          "stream_delta" => answer,
          "reasoning" => reasoning,
          "tool_call" => tool
        }
      }

      assert {:ok, ^policy} = LiveUpdates.normalize(policy)
      assert {:ok, ^policy} = LiveUpdates.normalize(Jason.decode!(Jason.encode!(policy)))
      assert {:ok, ^policy} = LiveUpdates.from_settings(%{"live_updates" => policy})
    end
  end

  property "nonpositive integers cannot be used to disable throttling implicitly" do
    check all(interval <- integer(), interval <= 0) do
      assert {:error, %{"min_interval_ms" => _}} =
               LiveUpdates.normalize(%{"min_interval_ms" => interval})
    end
  end
end
