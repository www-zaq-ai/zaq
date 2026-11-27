defmodule Zaq.System.ConfidentialityDefaultsTest do
  use Zaq.DataCase, async: true

  alias Zaq.System, as: SystemConfig
  alias Zaq.System.Config

  test "independent defaults initially resolve to zero without policy rows" do
    assert SystemConfig.get_confidentiality_defaults() ==
             {:ok, %{classification_level: 0, clearance_level: 0}}
  end

  test "persistent explicit values are parsed without lossy fallbacks" do
    SystemConfig.set_config("system.confidentiality.classification_level", "3")

    assert SystemConfig.get_confidentiality_defaults() ==
             {:ok, %{classification_level: 3, clearance_level: 0}}

    SystemConfig.set_config("system.confidentiality.clearance_level", "0")

    assert SystemConfig.get_confidentiality_defaults() ==
             {:ok, %{classification_level: 3, clearance_level: 0}}

    for invalid <- ["", "-1", "garbage", "1.0", "2147483648"] do
      SystemConfig.set_config("system.confidentiality.clearance_level", invalid)

      assert SystemConfig.get_confidentiality_defaults() ==
               {:error, :invalid_confidentiality_defaults}
    end
  end

  test "stored boundary integer strings cast independently; oversized strings fail closed" do
    SystemConfig.set_config("system.confidentiality.classification_level", "2147483647")
    SystemConfig.set_config("system.confidentiality.clearance_level", "+002")

    assert SystemConfig.get_confidentiality_defaults() ==
             {:ok, %{classification_level: 2_147_483_647, clearance_level: 2}}

    SystemConfig.set_config("system.confidentiality.clearance_level", String.duplicate("0", 32))

    assert SystemConfig.get_confidentiality_defaults() ==
             {:error, :invalid_confidentiality_defaults}
  end

  test "a persisted null is invalid, not an absent setting or inherited override" do
    for field <- [:classification_level, :clearance_level] do
      row = Repo.insert!(%Config{key: "system.confidentiality.#{field}", value: nil})

      assert SystemConfig.get_confidentiality_defaults() ==
               {:error, :invalid_confidentiality_defaults}

      Repo.delete!(row)
    end
  end
end
