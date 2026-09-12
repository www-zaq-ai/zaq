defmodule Zaq.Accounts.ChannelIdentityConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.{People, Person, PersonChannel}
  alias Zaq.Repo

  test "discovery propagates unrelated unique violations without retrying or leaving an orphan" do
    marker = "unrelated-unique-#{System.unique_integer([:positive])}"
    handler = {__MODULE__, self()}
    owner = self()

    Sandbox.unboxed_run(Repo, fn ->
      {:ok, original} = People.create_person(%{full_name: marker})

      try do
        Repo.query!(
          "CREATE UNIQUE INDEX people_identity_test_name_index ON people (full_name) WHERE full_name = '#{marker}'"
        )

        :telemetry.attach(
          handler,
          [:zaq, :repo, :query],
          fn _, _, metadata, _ ->
            if self() == owner and metadata[:source] == "people" and
                 String.starts_with?(metadata.query, "INSERT") do
              send(owner, :discovery_insert)
            end
          end,
          nil
        )

        error =
          assert_raise Ecto.ConstraintError, fn ->
            People.find_or_create_from_channel(:telegram, %{
              channel_id: marker,
              display_name: marker
            })
          end

        assert error.constraint == "people_identity_test_name_index"
        assert_received :discovery_insert
        refute_received :discovery_insert
        assert People.get_person!(original.id) == original
        assert People.list_person_channels(original.id) == []
        assert Repo.aggregate(from(p in Person, where: p.full_name == ^marker), :count) == 1
      after
        :telemetry.detach(handler)
        Repo.query!("DROP INDEX IF EXISTS people_identity_test_name_index")
        Repo.delete_all(from p in Person, where: p.full_name == ^marker)
      end
    end)
  end

  for platform <- ["email", "telegram"] do
    test "independent connections cannot assign the same #{platform} identity to two people" do
      marker = "channel-race-#{System.unique_integer([:positive])}"

      ids =
        Sandbox.unboxed_run(Repo, fn ->
          for _ <- 1..2 do
            {:ok, person} = People.create_person(%{full_name: marker})
            person.id
          end
        end)

      cleanup(marker)

      results =
        race(ids, fn id ->
          identifier =
            if unquote(platform) == "email",
              do: " #{String.upcase(marker)}@EXAMPLE.COM ",
              else: marker

          People.add_channel(%{
            person_id: id,
            platform: unquote(platform),
            channel_identifier: identifier
          })
        end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert [{:error, error}] = Enum.filter(results, &match?({:error, _}, &1))

      assert {"This channel identifier is already assigned.", _} =
               error.errors[:channel_identifier]

      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.aggregate(from(c in PersonChannel, where: c.person_id in ^ids), :count) == 1
      end)
    end

    test "concurrent #{platform} discovery rereads the committed winner without orphan people" do
      marker = "discovery-race-#{System.unique_integer([:positive])}"
      cleanup(marker)
      identifier = if unquote(platform) == "email", do: marker <> "@example.com", else: marker
      parent = self()
      # Hold both workers immediately after their initial missing channel read.
      # This proves the retry occurs after a real unique-index conflict, rather
      # than letting the second worker discover the first before it inserts.
      results =
        race(
          [1, 2],
          fn _ ->
            worker = self()
            handler = {__MODULE__, worker}

            :telemetry.attach(
              handler,
              [:zaq, :repo, :query],
              fn _, _, metadata, _ ->
                if self() == worker and metadata[:source] == "channels" and
                     String.starts_with?(metadata.query, "SELECT") and
                     not Process.get(handler, false) do
                  Process.put(handler, true)
                  send(parent, {:missing, worker})
                  receive do: (:insert -> :ok)
                end
              end,
              nil
            )

            try do
              People.find_or_create_from_channel(unquote(platform), %{
                channel_id: identifier,
                display_name: marker
              })
            after
              :telemetry.detach(handler)
            end
          end,
          fn ->
            workers =
              for _ <- 1..2 do
                assert_receive {:missing, worker}, 5_000
                worker
              end

            Enum.each(workers, &send(&1, :insert))
          end
        )

      assert [{:ok, first}, {:ok, second}] = results
      assert first.id == second.id

      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.aggregate(from(p in Person, where: p.full_name == ^marker), :count) == 1
        assert length(People.list_person_channels(first.id)) == 1
      end)
    end
  end

  test "concurrent canonical Person email creates roll back the losing Person" do
    marker = "person-race-#{System.unique_integer([:positive])}"
    cleanup(marker)

    results =
      race([" #{String.upcase(marker)}@EXAMPLE.COM ", marker <> "@example.com"], fn email ->
        People.create_person(%{full_name: marker, email: email})
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert [{:error, error}] = Enum.filter(results, &match?({:error, _}, &1))
    assert {"has already been taken", _} = error.errors[:email]

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(from(p in Person, where: p.full_name == ^marker), :count) == 1
    end)
  end

  test "concurrent discovery of one profile email retries after rollback and retains both incoming channels" do
    marker = "profile-discovery-#{System.unique_integer([:positive])}"
    email = marker <> "@example.com"
    cleanup(marker)
    parent = self()

    results =
      race(
        ["first", "second"],
        fn suffix ->
          worker = self()
          handler = {__MODULE__, worker}

          :telemetry.attach(
            handler,
            [:zaq, :repo, :query],
            fn _, _, metadata, _ ->
              if self() == worker and metadata[:source] == "people" and
                   String.starts_with?(metadata.query, "SELECT") and
                   not Process.get(handler, false) do
                Process.put(handler, true)
                send(parent, {:missing_profile, worker})
                receive do: (:insert -> :ok)
              end
            end,
            nil
          )

          try do
            People.find_or_create_from_channel(:telegram, %{
              channel_id: marker <> suffix,
              email: email,
              display_name: marker
            })
          after
            :telemetry.detach(handler)
          end
        end,
        fn ->
          workers =
            for _ <- 1..2 do
              assert_receive {:missing_profile, worker}, 5_000
              worker
            end

          Enum.each(workers, &send(&1, :insert))
        end
      )

    assert [{:ok, first}, {:ok, second}] = results
    assert first.id == second.id

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(from(p in Person, where: p.email == ^email), :count) == 1

      assert People.list_person_channels(first.id)
             |> Enum.map(&{&1.platform, &1.channel_identifier})
             |> Enum.sort() == [
               {"email", email},
               {"telegram", marker <> "first"},
               {"telegram", marker <> "second"}
             ]
    end)
  end

  defp race(inputs, operation, coordinate \\ fn -> :ok end) do
    parent = self()

    tasks = Enum.map(inputs, &start_racer(parent, &1, operation))

    for _ <- tasks, do: assert_receive({:ready, _}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    coordinate.()
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp start_racer(parent, input, operation) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        send(parent, {:ready, self()})
        receive do: (:go -> operation.(input))
      end)
    end)
  end

  defp cleanup(marker) do
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from p in Person, where: p.full_name == ^marker)
      end)
    end)
  end
end
