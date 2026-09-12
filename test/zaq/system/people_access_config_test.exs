defmodule Zaq.System.PeopleAccessConfigTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ecto.Changeset
  alias Zaq.System.PeopleAccessConfig

  test "defaults are typed, including a seven day session" do
    assert {:ok, config} =
             PeopleAccessConfig.changeset(%PeopleAccessConfig{}, %{})
             |> Changeset.apply_action(:validate)

    assert Map.from_struct(config) == %{
             otp_validity_seconds: 300,
             otp_max_attempts: 5,
             unknown_email_attempt_limit: 10,
             unknown_email_window_seconds: 600,
             unknown_email_cooldown_seconds: 900,
             otp_send_person_limit: 5,
             otp_send_ip_limit: 20,
             otp_send_window_seconds: 900,
             session_lifetime_seconds: 604_800
           }
  end

  test "rejects malformed values rather than casting or substituting defaults" do
    for field <- PeopleAccessConfig.__schema__(:fields),
        value <- [
          1.0,
          1.5,
          "1.0",
          "1tail",
          "1 ",
          " 1",
          "",
          nil,
          0,
          -1,
          "0",
          "-1",
          true,
          false,
          %{},
          [],
          [1]
        ] do
      changeset = PeopleAccessConfig.changeset(%PeopleAccessConfig{}, %{field => value})
      refute changeset.valid?, "accepted #{field}=#{inspect(value)}"
      assert Keyword.has_key?(changeset.errors, field)
    end
  end

  test "known atom and string keys work; atom keys win duplicates; unknown keys are ignored" do
    changeset =
      PeopleAccessConfig.changeset(%PeopleAccessConfig{}, %{
        :otp_max_attempts => 7,
        "otp_max_attempts" => "9",
        "otp_send_ip_limit" => "30",
        "untrusted_new_setting" => 42
      })

    assert changeset.valid?
    assert Changeset.get_field(changeset, :otp_max_attempts) == 7
    assert Changeset.get_field(changeset, :otp_send_ip_limit) == 30
    refute Map.has_key?(changeset.changes, :untrusted_new_setting)

    assert_raise ArgumentError, fn ->
      String.to_existing_atom("people_access_never_intern_this_key_987654")
    end

    assert PeopleAccessConfig.changeset(%PeopleAccessConfig{}, %{
             "people_access_never_intern_this_key_987654" => 1
           }).valid?

    assert_raise ArgumentError, fn ->
      String.to_existing_atom("people_access_never_intern_this_key_987654")
    end
  end

  test "malformed containers and client changesets are rejected" do
    for attrs <- [nil, [], true, "bad", Changeset.change(%PeopleAccessConfig{})] do
      refute PeopleAccessConfig.changeset(%PeopleAccessConfig{}, attrs).valid?
    end
  end

  property "positive integers and their decimal representation normalize identically without a product maximum" do
    check all(
            value <- positive_integer(),
            field <- member_of(PeopleAccessConfig.__schema__(:fields))
          ) do
      for input <- [value, Integer.to_string(value)] do
        changeset = PeopleAccessConfig.changeset(%PeopleAccessConfig{}, %{field => input})
        assert changeset.valid?
        assert Changeset.get_field(changeset, field) === value
      end
    end

    large = Integer.pow(2, 100)

    assert Changeset.get_field(
             PeopleAccessConfig.changeset(%PeopleAccessConfig{}, %{
               session_lifetime_seconds: to_string(large)
             }),
             :session_lifetime_seconds
           ) == large
  end

  property "appending non-numeric junk never accepts a numeric prefix" do
    check all(value <- positive_integer(), suffix <- string(?a..?z, min_length: 1)) do
      refute PeopleAccessConfig.changeset(%PeopleAccessConfig{}, %{
               otp_max_attempts: "#{value}#{suffix}"
             }).valid?
    end
  end
end
