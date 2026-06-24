defmodule Zaq.Agent.Tools.DataSource.CreateFolderTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.DataSource.CreateFolder
  alias Zaq.Event

  @folder_mime "application/vnd.google-apps.folder"

  # Configurable stub: per-action responses are read from the process dictionary
  # so each test can shape get_file / list_files / create_file independently.
  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      action = opts[:action]
      send(self(), {:dispatch, action, params})
      %{Event.new(%{}, :channels) | response: response_for(action)}
    end

    defp response_for(action) do
      Process.get({:response, action}, default_response(action))
    end

    defp default_response(:data_source_get_file),
      do: {:ok, %{record: %{kind: :folder, name: "Zaq"}}}

    defp default_response(:data_source_list_files), do: {:ok, %{records: []}}

    defp default_response(:data_source_create_file),
      do: {:ok, %{status: "created", record: %{"id" => "fld1"}}}
  end

  defp stub_response(action, response), do: Process.put({:response, action}, response)

  test "creates a folder at the root when no parent_id is given" do
    assert {:ok, %{status: "created", record: %{"id" => "fld1"}}} =
             CreateFolder.run(%{provider: "google_drive", name: "jad_test_zaq"}, %{
               node_router: StubNodeRouter
             })

    # No parent lookup when none requested.
    refute_received {:dispatch, :data_source_get_file, _}

    # Duplicate scan scoped to folders (no parent filter at root).
    assert_received {:dispatch, :data_source_list_files, %{"filters" => %{"kind" => "folder"}}}

    # Created with the folder MIME and no parents.
    assert_received {:dispatch, :data_source_create_file, create_params}
    assert create_params["name"] == "jad_test_zaq"
    assert create_params["mime_type"] == @folder_mime
    refute Map.has_key?(create_params, "parents")
  end

  test "nests the folder inside a parent by passing parents: [parent_id]" do
    # Scenario: create jad_test_zaq inside the folder Zaq (resolved id "zaq_id").
    assert {:ok, %{status: "created"}} =
             CreateFolder.run(
               %{provider: "google_drive", name: "jad_test_zaq", parent_id: "zaq_id"},
               %{node_router: StubNodeRouter}
             )

    # Parent is validated by id.
    assert_received {:dispatch, :data_source_get_file, %{"file_id" => "zaq_id"}}

    # Duplicate scan scoped to subfolders of the parent.
    assert_received {:dispatch, :data_source_list_files,
                     %{"filters" => %{"kind" => "folder", "parent" => "zaq_id"}}}

    # Nested via the provider's parents array (not a scalar parent_id).
    assert_received {:dispatch, :data_source_create_file, create_params}
    assert create_params["name"] == "jad_test_zaq"
    assert create_params["parents"] == ["zaq_id"]
    assert create_params["mime_type"] == @folder_mime
  end

  test "returns the existing folder instead of creating a duplicate" do
    stub_response(
      :data_source_list_files,
      {:ok,
       %{
         records: [
           %{kind: :file, name: "jad_test_zaq"},
           %{kind: :folder, name: "jad_test_zaq", id: "ex1"}
         ]
       }}
    )

    assert {:ok, %{status: "exists", record: %{id: "ex1"}}} =
             CreateFolder.run(
               %{provider: "google_drive", name: "jad_test_zaq", parent_id: "zaq_id"},
               %{node_router: StubNodeRouter}
             )

    refute_received {:dispatch, :data_source_create_file, _}
  end

  test "fails when the parent_id does not exist and does not create" do
    stub_response(:data_source_get_file, {:error, :not_found})

    assert {:error, message} =
             CreateFolder.run(
               %{provider: "google_drive", name: "jad_test_zaq", parent_id: "missing"},
               %{node_router: StubNodeRouter}
             )

    assert message == ~s(Parent folder "missing" was not found)
    refute_received {:dispatch, :data_source_create_file, _}
  end

  test "caller-supplied mime_type overrides the default folder MIME" do
    assert {:ok, _} =
             CreateFolder.run(
               %{provider: "google_drive", name: "Reports", mime_type: "custom/folder"},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_create_file, %{"mime_type" => "custom/folder"}}
  end

  test "passes config_id through to every dispatch" do
    assert {:ok, _} =
             CreateFolder.run(
               %{provider: "google_drive", name: "Reports", parent_id: "zaq_id", config_id: "12"},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_get_file, %{"config_id" => "12"}}
    assert_received {:dispatch, :data_source_list_files, %{"config_id" => "12"}}
    assert_received {:dispatch, :data_source_create_file, %{"config_id" => "12"}}
  end

  test "formats datasource error reason from create" do
    stub_response(:data_source_create_file, {:error, :timeout})

    assert {:error, message} =
             CreateFolder.run(%{provider: "google_drive", name: "Reports"}, %{
               node_router: StubNodeRouter
             })

    assert message == "Data source folder creation failed: :timeout"
  end

  test "returns unexpected response error from create" do
    stub_response(:data_source_create_file, :ok)

    assert {:error, message} =
             CreateFolder.run(%{provider: "google_drive", name: "Reports"}, %{
               node_router: StubNodeRouter
             })

    assert message == "Unexpected data source response: :ok"
  end
end
