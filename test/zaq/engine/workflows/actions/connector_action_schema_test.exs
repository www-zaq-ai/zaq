defmodule Zaq.Engine.Workflows.Actions.ConnectorActionSchemaTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Actions.SaveEmailConnector
  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.Actions.{ArchiveChannelConnector, RefreshChannelHistoryMembership}

  @save_params %{provider: "email:smtp", selected_config_id: nil, params: %{}}
  @archive_params %{channel_config_id: 42, provider: "mattermost", kind: "retrieval"}

  test "all affected Actions expose Zoi input and output schemas" do
    for action <- [SaveEmailConnector, ArchiveChannelConnector, RefreshChannelHistoryMembership] do
      assert %Zoi.Types.Map{} = action.schema()
      assert %Zoi.Types.Map{} = action.output_schema()
    end

    assert :ok = Action.validate(ArchiveChannelConnector)
    assert :ok = Action.validate(RefreshChannelHistoryMembership)
  end

  test "email selection retains nil, new and exact connector forms" do
    for selection <- [nil, :new, "new", 42, "42"] do
      params = %{@save_params | selected_config_id: selection}
      assert {:ok, ^params} = SaveEmailConnector.validate_params(params)
    end
  end

  property "required Action fields cannot disappear during validation" do
    check all(
            {action, params, field} <-
              member_of([
                {SaveEmailConnector, @save_params, :provider},
                {SaveEmailConnector, @save_params, :selected_config_id},
                {SaveEmailConnector, @save_params, :params},
                {ArchiveChannelConnector, @archive_params, :channel_config_id},
                {ArchiveChannelConnector, @archive_params, :provider},
                {ArchiveChannelConnector, @archive_params, :kind}
              ])
          ) do
      assert {:error, _} = action.validate_params(Map.delete(params, field))
    end
  end

  test "typed fields reject malformed values" do
    assert {:error, _} = SaveEmailConnector.validate_params(%{@save_params | provider: 42})

    for {key, value} <- [channel_config_id: "42", provider: 42, kind: false] do
      assert {:error, _} =
               ArchiveChannelConnector.validate_params(Map.put(@archive_params, key, value))
    end

    for {key, value} <- [transcript_id: 42, person_id: "42", channel_config_id: "42"] do
      assert {:error, _} = RefreshChannelHistoryMembership.validate_params(%{key => value})
    end
  end

  test "refresh scope fields remain optional and do not receive invented defaults" do
    for params <- [%{}, %{transcript_id: "transcript"}, %{person_id: 1, channel_config_id: 42}] do
      assert {:ok, ^params} = RefreshChannelHistoryMembership.validate_params(params)
    end
  end

  test "email output preserves wrapped success and domain-error tuples" do
    for result <- [{:ok, %{selected_config_id: 42}}, {:error, :connector_mismatch}] do
      assert {:ok, %{result: ^result}} = SaveEmailConnector.validate_output(%{result: result})
    end

    assert {:error, _} = SaveEmailConnector.validate_output(%{})
  end

  test "archive and refresh outputs retain their map and count contracts" do
    output = %{result: %{channel_config_id: 42, status: :archived}}
    assert {:ok, ^output} = ArchiveChannelConnector.validate_output(output)
    assert {:error, _} = ArchiveChannelConnector.validate_output(%{})
    assert {:error, _} = ArchiveChannelConnector.validate_output(%{result: :archived})

    for output <- [%{members: 2}, %{members: 2, rooms: 1}] do
      assert {:ok, ^output} = RefreshChannelHistoryMembership.validate_output(output)
    end

    for output <- [%{}, %{members: "2"}, %{members: 2, rooms: "1"}] do
      assert {:error, _} = RefreshChannelHistoryMembership.validate_output(output)
    end
  end

  test "Exec still rejects invalid inputs and cannot bypass actor authorization" do
    for {action, params} <- [
          {SaveEmailConnector, @save_params},
          {ArchiveChannelConnector, @archive_params},
          {RefreshChannelHistoryMembership, %{transcript_id: "transcript"}}
        ] do
      assert {:error, _} = Jido.Exec.run(action, params, %{})
      assert {:error, _} = Jido.Exec.run(action, %{provider: 42, transcript_id: 42}, %{})
    end
  end

  test "non-map params or context return unauthorized from the callback fallback" do
    for params <- [nil, [], "invalid"] do
      assert {:error, :unauthorized} = SaveEmailConnector.run(params, %{})
    end

    for context <- [nil, [], "invalid"] do
      assert {:error, :unauthorized} = SaveEmailConnector.run(@save_params, context)
    end
  end
end
