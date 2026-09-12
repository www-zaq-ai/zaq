defmodule Zaq.System.PeopleAccessPersistenceTest do
  use Zaq.DataCase, async: false

  alias Zaq.System
  alias Zaq.System.Config
  alias Zaq.System.PeopleAccessConfig

  test "cold read makes one group SELECT and no writes" do
    owner = self()
    handler = "people-access-queries-#{Elixir.System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:zaq, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == owner, do: send(owner, {:query, metadata.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, %PeopleAccessConfig{session_lifetime_seconds: 604_800}} =
             System.get_people_access_config()

    assert_received {:query, query}
    assert query =~ "SELECT"
    assert query =~ "system_configs"
    refute_received {:query, _}
    assert Repo.aggregate(from(c in Config, where: like(c.key, "people_access.%")), :count) == 0
  end

  test "partial saves preserve current values and write only canonical numeric keys" do
    assert {:ok, _} = System.set_config("people_access.otp_max_attempts", "17")

    assert {:ok, config} =
             System.save_people_access_config(%{
               "session_lifetime_seconds" => "864000",
               "unknown" => "123"
             })

    assert config.otp_max_attempts == 17
    assert config.session_lifetime_seconds == 864_000
    assert {:ok, ^config} = System.save_people_access_config(%{})
    assert {:ok, ^config} = System.get_people_access_config()
    assert Repo.aggregate(from(c in Config, where: like(c.key, "people_access.%")), :count) == 9
    assert System.get_config("people_access.unknown") == nil
    assert System.get_config("people_access.session_lifetime_seconds") == "864000"
  end

  test "corrupt persisted values error explicitly; partial save cannot hide corruption; full valid save repairs" do
    for value <- ["300junk", "", "1.0", "0", "-1"] do
      assert {:ok, _} = System.set_config("people_access.otp_validity_seconds", value)

      assert {:error, {:invalid_people_access_config, changeset}} =
               System.get_people_access_config()

      assert Keyword.has_key?(changeset.errors, :otp_validity_seconds)

      assert {:error, {:invalid_people_access_config, _}} =
               System.save_people_access_config(%{otp_max_attempts: 8})
    end

    assert {:ok, %PeopleAccessConfig{}} =
             System.save_people_access_config(Map.from_struct(%PeopleAccessConfig{}))

    assert {:ok, %PeopleAccessConfig{otp_validity_seconds: 300}} =
             System.get_people_access_config()
  end

  test "invalid attrs and forged changesets never write" do
    assert {:ok, initial} = System.save_people_access_config(%{otp_max_attempts: 12})

    for attrs <- [
          %{otp_max_attempts: 0},
          %{otp_max_attempts: nil},
          nil,
          [],
          Ecto.Changeset.change(initial, otp_max_attempts: -1)
        ] do
      assert {:error, %Ecto.Changeset{valid?: false}} = System.save_people_access_config(attrs)
      assert {:ok, ^initial} = System.get_people_access_config()
    end
  end

  test "a later database failure rolls back earlier config rows" do
    assert {:ok, initial} = System.save_people_access_config(%{})
    # Transaction-scoped trigger, rolled back by Sandbox. Reuse the schema's
    # declared unique constraint so set_config returns an error changeset.
    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_people_access_config() RETURNS trigger AS $$
    BEGIN
      IF NEW.key = 'people_access.session_lifetime_seconds' AND NEW.value = '999' THEN
        RAISE EXCEPTION 'injected later row failure' USING ERRCODE = '23505', CONSTRAINT = 'system_configs_key_index';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!(
      "CREATE TRIGGER reject_people_access_config BEFORE INSERT OR UPDATE ON system_configs FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_people_access_config()"
    )

    assert {:error, %Ecto.Changeset{}} =
             System.save_people_access_config(%{
               otp_max_attempts: 99,
               session_lifetime_seconds: 999
             })

    assert {:ok, ^initial} = System.get_people_access_config()
  end
end
