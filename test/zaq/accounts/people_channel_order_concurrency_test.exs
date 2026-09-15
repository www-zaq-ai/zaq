defmodule Zaq.Accounts.PeopleChannelOrderConcurrencyTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions, Person, Team}
  alias Zaq.Repo
  alias ZaqWeb.Live.People.ProfileLive

  setup do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, person} = People.create_person(%{full_name: "Order concurrency"})

        channels =
          for index <- 1..3 do
            {:ok, channel} =
              People.add_channel(%{
                person_id: person.id,
                platform: "slack",
                channel_identifier: "order-#{person.id}-#{index}"
              })

            channel
          end

        %{
          person: person,
          channels: channels,
          expected: Enum.map(channels, &Map.take(&1, [:id, :weight]))
        }
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn -> Repo.get(Person, fixture.person.id) |> Repo.delete!() end)
    end)

    fixture
  end

  test "two concurrent drafts cannot both replace the same original order", %{
    person: p,
    channels: channels,
    expected: expected
  } do
    parent = self()

    tasks =
      for order <- [Enum.reverse(channels), tl(channels) ++ [hd(channels)]] do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> People.update_self_channel_order(p, Enum.map(order, & &1.id), expected)
            end
          end)
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, pid}, 5_000
      send(pid, :go)
    end

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_order})) == 1
  end

  test "a later database rejection rolls back every earlier channel weight", %{
    person: p,
    channels: [first, second, third],
    expected: expected
  } do
    Sandbox.unboxed_run(Repo, fn ->
      constraint = "profile_order_rollback_#{p.id}"

      Repo.query!(
        "ALTER TABLE channels ADD CONSTRAINT #{constraint} CHECK (id <> #{first.id} OR weight <> 1)"
      )

      try do
        assert_raise Ecto.ConstraintError, fn ->
          People.update_self_channel_order(p, [second.id, first.id, third.id], expected)
        end

        assert Enum.map(People.list_person_channels(p.id), &Map.take(&1, [:id, :weight])) ==
                 expected
      after
        Repo.query!("ALTER TABLE channels DROP CONSTRAINT #{constraint}")
      end
    end)
  end

  test "BO swap loaded before an in-flight reorder uses the committed fresh weights", %{
    person: p,
    channels: [a, b, c],
    expected: expected
  } do
    parent = self()

    reorder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            assert {:ok, _} = People.update_self_channel_order(p, [b.id, a.id, c.id], expected)
            send(parent, :reordered)

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive :reordered, 5_000

    swap =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          send(parent, :swapping)
          # BO's descending argument order must not dictate row lock order.
          People.swap_channel_weights(c, b)
        end)
      end)

    assert_receive :swapping, 5_000
    send(reorder.pid, :commit)
    assert {:ok, :ok} = Task.await(reorder, 5_000)
    assert {:ok, {:ok, _}} = Task.await(swap, 5_000)

    Sandbox.unboxed_run(Repo, fn ->
      assert Enum.map(People.list_person_channels(p.id), &{&1.id, &1.weight}) == [
               {c.id, 0},
               {a.id, 1},
               {b.id, 2}
             ]
    end)
  end

  test "an in-flight BO swap makes the waiting profile draft stale", %{
    person: p,
    channels: [a, b, c],
    expected: expected
  } do
    parent = self()

    swap =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            assert {:ok, _} = People.swap_channel_weights(c, b)
            send(parent, :swapped)

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive :swapped, 5_000

    reorder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          send(parent, :reordering)
          People.update_self_channel_order(p, [b.id, a.id, c.id], expected)
        end)
      end)

    assert_receive :reordering, 5_000
    send(swap.pid, :commit)
    assert {:ok, :ok} = Task.await(swap, 5_000)
    assert {:error, :stale_order} = Task.await(reorder, 5_000)

    Sandbox.unboxed_run(Repo, fn ->
      assert Enum.map(People.list_person_channels(p.id), &{&1.id, &1.weight}) == [
               {a.id, 0},
               {c.id, 1},
               {b.id, 2}
             ]
    end)
  end

  test "a database write failure preserves the name draft and permits retry without logging bearer",
       %{person: p} do
    Sandbox.unboxed_run(Repo, fn ->
      {:ok, team} = People.create_team(%{name: "Order fault #{p.id}"})

      try do
        {:ok, p} = People.assign_team(p, team.id)
        {:ok, _} = PeoplePermissions.grant({:team, team.id}, :access_profile)
        {:ok, _} = PeoplePermissions.grant({:team, team.id}, :edit_profile)
        {:ok, challenge} = PeopleAuth.issue_challenge(p, {127, 3, 1, 1})

        {:ok, %{token: token}} =
          PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code)

        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
        {:ok, mounted} = ProfileLive.mount(%{}, %{"person_session_token" => token}, socket)
        {:noreply, editing} = ProfileLive.handle_event("edit_name", %{}, mounted)
        # Existing name validation does not add a prototype length rule; exercise
        # a genuine PostgreSQL varchar rejection after the request is authorized.
        name = String.duplicate("x", 300)

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            {:noreply, failed} =
              ProfileLive.handle_event(
                "save_profile",
                %{"profile" => %{"full_name" => name}},
                editing
              )

            assert failed.assigns.mode == :name
            assert failed.assigns.name_form[:full_name].value == name
            assert Phoenix.Flash.get(failed.assigns.flash, :error) =~ "draft is kept"
            assert People.get_person(p.id).full_name == p.full_name

            {:noreply, saved} =
              ProfileLive.handle_event(
                "save_profile",
                %{"profile" => %{"full_name" => "Recovered"}},
                failed
              )

            assert saved.assigns.mode == :read
            assert People.get_person(p.id).full_name == "Recovered"
          end)

        refute log =~ token
      after
        Repo.get!(Team, team.id) |> Repo.delete!()
      end
    end)
  end

  for writer <- [:insert, :delete, :weight] do
    test "#{writer} writer commits before waiting reorder and invalidates its snapshot", %{
      person: p,
      channels: channels,
      expected: expected
    } do
      writer = unquote(writer)
      parent = self()

      task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              write(writer, p, channels)

              send(parent, :written)

              receive do
                :commit -> :ok
              end
            end)
          end)
        end)

      assert_receive :written, 5_000

      reorder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, :reordering)

            People.update_self_channel_order(
              p,
              Enum.map(Enum.reverse(channels), & &1.id),
              expected
            )
          end)
        end)

      assert_receive :reordering, 5_000
      send(task.pid, :commit)
      assert {:ok, :ok} = Task.await(task, 5_000)
      assert {:error, :stale_order} = Task.await(reorder, 5_000)
    end
  end

  defp write(:insert, p, _),
    do:
      People.add_channel(%{person_id: p.id, platform: "slack", channel_identifier: "new-#{p.id}"})

  defp write(:delete, _, channels), do: People.delete_channel(hd(channels))

  defp write(:weight, p, channels),
    do: People.update_self_channel_weight(p, hd(channels).id, %{weight: 99})
end
