defmodule Zaq.Engine.Connect.OAuth.Behaviours.CodexTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Connect.OAuth.Behaviours.Codex

  test "accepts only valid Codex account metadata" do
    assert Codex.valid_grant_metadata?(%{})
    assert Codex.valid_grant_metadata?(%{"chatgpt_account_id" => "acct_123"})

    refute Codex.valid_grant_metadata?(%{"unexpected" => "value"})
    refute Codex.valid_grant_metadata?(%{chatgpt_account_id: "acct_123"})

    refute Codex.valid_grant_metadata?(%{
             "chatgpt_account_id" => "acct_123",
             "secret" => "synthetic-secret"
           })

    refute Codex.valid_grant_metadata?(%{"chatgpt_account_id" => ""})
    refute Codex.valid_grant_metadata?(%{"chatgpt_account_id" => nil})
    refute Codex.valid_grant_metadata?(%{"chatgpt_account_id" => 123})
  end

  test "rejects non-map metadata" do
    inputs = [
      nil,
      false,
      42,
      "acct_123",
      [],
      [{"chatgpt_account_id", "acct_123"}],
      {:account, "acct_123"}
    ]

    Enum.each(inputs, fn input ->
      assert Codex.valid_grant_metadata?(input) === false
      assert Codex.runtime_identity(input) === %{}
    end)
  end

  property "unknown metadata keys always reject" do
    check all(
            key <- string(:alphanumeric, min_length: 1, max_length: 30),
            value <-
              one_of([integer(), string(:alphanumeric, max_length: 30), boolean(), constant(nil)]),
            key not in ["chatgpt_account_id"]
          ) do
      refute Codex.valid_grant_metadata?(%{
               "chatgpt_account_id" => "acct_123",
               key => value
             })
    end
  end

  property "non-map metadata fails closed" do
    check all(
            input <-
              one_of([
                integer(),
                string(:alphanumeric, max_length: 30),
                boolean(),
                constant(nil),
                list_of(integer(), max_length: 3),
                tuple({integer(), string(:alphanumeric, max_length: 30)})
              ])
          ) do
      assert Codex.valid_grant_metadata?(input) === false
      assert Codex.runtime_identity(input) === %{}
    end
  end

  test "runtime identity enforces a 255-byte limit" do
    within_limit = String.duplicate("a", 255)
    oversized_ascii = String.duplicate("a", 256)
    oversized_utf8 = String.duplicate("é", 128)

    assert Codex.runtime_identity(%{"chatgpt_account_id" => within_limit}) == %{
             "chatgpt_account_id" => within_limit
           }

    assert Codex.valid_grant_metadata?(%{"chatgpt_account_id" => oversized_ascii})
    assert Codex.valid_grant_metadata?(%{"chatgpt_account_id" => oversized_utf8})
    assert Codex.runtime_identity(%{"chatgpt_account_id" => oversized_ascii}) == %{}
    assert Codex.runtime_identity(%{"chatgpt_account_id" => oversized_utf8}) == %{}
  end
end
