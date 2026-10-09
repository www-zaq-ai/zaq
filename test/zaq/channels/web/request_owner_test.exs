defmodule Zaq.Channels.Web.RequestOwnerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Web.{Delivery, RequestOwner, Response}

  setup do
    topic = "fixture:#{Ecto.UUID.generate()}"
    Phoenix.PubSub.subscribe(Zaq.PubSub, topic)

    {:ok, delivery} =
      Delivery.new(%{
        consumer: :widget,
        topic: topic,
        channel_config_id: 1,
        events:
          Map.new(
            [
              :typing,
              :message_create,
              :message_edit,
              :message_step,
              :message_complete,
              :message_failed,
              :error
            ],
            &{&1, Atom.to_string(&1)}
          )
      })

    %{delivery: delivery}
  end

  test "one owner creates before replacement updates and suppresses a second terminal", %{
    delivery: delivery
  } do
    {pid, internal} = owner(delivery, :async)
    ref = Process.monitor(pid)

    assert {:ok, %Response{type: :conversation_created, conversation_id: "chat"}} =
             RequestOwner.run(pid, fn -> :ok end)

    assert_receive {:web_response, "typing", %Response{payload: %{active: true}}}
    assert_receive {:web_response, "message_create", %Response{message_id: assistant}}
    publish(internal, :message_edit, %{body: "Full snapshot"})

    assert_receive {:web_response, "message_edit",
                    %Response{message_id: ^assistant, payload: %{body: "Full snapshot"}}}

    publish(internal, :message_edit, %{body: "Full snapshot revised"})

    assert_receive {:web_response, "message_edit",
                    %Response{payload: %{body: "Full snapshot revised"}}}

    publish(internal, :message_complete, %{body: "Final"})
    publish(internal, :message_failed, %{body: "Duplicate fallback"})
    assert_receive {:web_response, "typing", %Response{payload: %{active: false}}}
    assert_receive {:web_response, "message_complete", %Response{message_id: ^assistant}}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    refute_receive {:web_response, "message_failed", _}
  end

  test "visible steps replace raw reasoning with a fixed public summary", %{delivery: delivery} do
    {pid, internal} = owner(delivery, :async)
    RequestOwner.run(pid, fn -> :ok end)
    publish(internal, :status, %{body: "secret reasoning and arguments", stage: :retrieving})
    assert_receive {:web_response, "message_step", %Response{payload: payload}}
    assert payload.label == "Retrieving information"
    refute Map.has_key?(payload, :body)
    publish(internal, :message_complete, %{body: "Done"})
  end

  test "sync returns one terminal and publishes no duplicate to its consumer", %{
    delivery: delivery
  } do
    {pid, internal} = owner(delivery, :sync)

    result =
      Task.async(fn ->
        RequestOwner.run(pid, fn ->
          publish(internal, :message_complete, %{body: "Done"})
          :ok
        end)
      end)

    assert %Response{type: :message_complete, payload: %{body: "Done", created: true}} =
             Task.await(result)

    refute_receive {:web_response, _, _}
  end

  test "timeout is an unknown outcome and does not cancel accepted work", %{delivery: delivery} do
    {pid, _internal} = owner(delivery, :sync, 20)
    parent = self()

    assert %Response{type: :error, payload: %{code: :timeout, outcome: :unknown}} =
             RequestOwner.run(pid, fn ->
               send(parent, {:worker, self()})

               receive do
                 :continue -> send(parent, :work_continued)
               end

               :ok
             end)

    assert_receive {:worker, worker}
    assert Process.alive?(worker)
    send(worker, :continue)
    assert_receive :work_continued
  end

  test "a dispatch failure after acceptance has one safe terminal", %{delivery: delivery} do
    {pid, _internal} = owner(delivery, :sync)

    assert %Response{type: :message_failed, payload: %{code: :dispatch_error}} =
             RequestOwner.run(pid, fn -> {:error, %{credentials: "private"}} end)

    refute_receive {:web_response, _, _}
  end

  test "two requests sharing an adapter destination cannot consume each other's updates", %{
    delivery: delivery
  } do
    {first, a} = owner(delivery, :async)
    {second, b} = owner(delivery, :async)
    refute a.topic == b.topic
    RequestOwner.run(first, fn -> :ok end)
    RequestOwner.run(second, fn -> :ok end)
    publish(a, :message_complete, %{body: "Only A"})
    assert_receive {:web_response, "message_complete", %Response{payload: %{body: "Only A"}}}
    assert Process.alive?(second)
    publish(b, :message_complete, %{body: "Only B"})
    assert_receive {:web_response, "message_complete", %Response{payload: %{body: "Only B"}}}
  end

  property "generated terminal variants return once without consumer rebroadcast", %{
    delivery: delivery
  } do
    check all(
            type <- member_of([:message_complete, :message_failed]),
            body <- string(:alphanumeric, min_length: 1, max_length: 64),
            max_runs: 10
          ) do
      {pid, internal} = owner(delivery, :sync)

      assert %Response{type: ^type, payload: %{body: ^body}} =
               RequestOwner.run(pid, fn ->
                 publish(internal, type, %{body: body})
                 publish(internal, :message_failed, %{body: "duplicate"})
                 :ok
               end)

      refute_receive {:web_response, _, _}
      refute Process.alive?(pid)
    end
  end

  defp owner(delivery, mode, timeout \\ 1_000) do
    pid =
      start_supervised!(
        {RequestOwner,
         delivery: delivery,
         mode: mode,
         timeout: timeout,
         request_id: Ecto.UUID.generate(),
         conversation_id: "chat",
         created: true},
        id: make_ref()
      )

    {pid, RequestOwner.delivery(pid)}
  end

  defp publish(delivery, type, payload) do
    {:ok, response} = Response.new(%{request_id: "internal", type: type, payload: payload})
    Phoenix.PubSub.broadcast(Zaq.PubSub, delivery.topic, {:web_response, type, response})
  end
end
