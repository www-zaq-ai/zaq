defmodule Zaq.Engine.Connect.OAuthBehaviourTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Connect.OAuth.Behaviours.{Codex, Standard}

  test "Codex exports only its validated runtime identity" do
    assert Codex.runtime_identity(%{
             "chatgpt_account_id" => "acct_person",
             "account_id" => "wrong-contract",
             "secret" => "hidden"
           }) == %{"chatgpt_account_id" => "acct_person"}

    assert Codex.runtime_identity(%{"chatgpt_account_id" => ""}) == %{}
    assert Standard.runtime_identity(%{"chatgpt_account_id" => "acct_person"}) == %{}

    assert Standard.runtime_identity(%{
             "account_id" => "generic-account",
             "account_name" => "Generic",
             "secret" => "hidden"
           }) == %{"account_id" => "generic-account", "account_name" => "Generic"}
  end

  property "OAuth runtime identity never exports unrelated metadata" do
    check all(
            key <- string(:alphanumeric, min_length: 1, max_length: 30),
            value <- term(),
            key not in ["chatgpt_account_id", "account_id", "account_name"]
          ) do
      refute Map.has_key?(Codex.runtime_identity(%{key => value}), key)
      assert Standard.runtime_identity(%{key => value}) == %{}
    end
  end
end
