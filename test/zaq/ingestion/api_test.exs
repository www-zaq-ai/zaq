defmodule Zaq.Ingestion.ApiTest do
  # async: false — the record actions read the mounted volumes, which are set through
  # Application.put_env.
  use Zaq.DataCase, async: false

  alias Zaq.Event
  alias Zaq.Ingestion.Api
  alias Zaq.Ingestion.Document

  @volume "archives"

  setup do
    root = Path.join(System.tmp_dir!(), "zaq_ingestion_api_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    original = Application.get_env(:zaq, Zaq.Ingestion)

    Application.put_env(
      :zaq,
      Zaq.Ingestion,
      Keyword.merge(original || [], volumes: %{@volume => root})
    )

    on_exit(fn ->
      File.rm_rf(root)

      if is_nil(original) do
        Application.delete_env(:zaq, Zaq.Ingestion)
      else
        Application.put_env(:zaq, Zaq.Ingestion, original)
      end
    end)

    %{root: root}
  end

  defp handle(request, action) do
    request
    |> Event.new(:ingestion, opts: [action: action])
    |> Api.handle_event(action, nil)
    |> Map.fetch!(:response)
  end

  defp seed_file(root, relative_path, content) do
    absolute = Path.join(root, relative_path)
    absolute |> Path.dirname() |> File.mkdir_p!()
    File.write!(absolute, content)

    {:ok, document} =
      Document.create(%{source: Path.join(@volume, relative_path), content: content})

    document
  end

  test "delegates invoke to shared helper" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :ingestion)
    result = Api.handle_event(event, :invoke, nil)

    assert result.response == "HI"
  end

  test "returns unsupported action" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :ingestion)
    result = Api.handle_event(event, :unknown, nil)

    assert result.response == {:error, {:unsupported_action, :unknown}}
  end

  describe "record actions" do
    test "describe_document delegates and puts the entry on the response", %{root: root} do
      document = seed_file(root, "guide.md", "# guide")

      assert {:ok, entry} = handle(%{file_id: document.source}, :describe_document)

      assert entry.id == document.source
    end

    test "list_documents delegates", %{root: root} do
      document = seed_file(root, "guide.md", "# guide")

      assert {:ok, %{entries: entries}} = handle(%{params: %{}}, :list_documents)
      assert document.source in Enum.map(entries, & &1.id)
    end

    test "materialize_record delegates and passes the whole request through", %{root: root} do
      document = seed_file(root, "guide.md", "# guide")

      assert {:ok, %{content: content, encoding: "base64"}} =
               handle(
                 %{"encoding" => "base64", file_id: document.source},
                 :materialize_record
               )

      assert Base.decode64!(content) == "# guide"
    end

    test "persist_document delegates", %{root: root} do
      assert {:ok, %{status: "created", entry: entry}} =
               handle(
                 %{"name" => "notes.md", "path" => @volume, "content" => "# notes"},
                 :persist_document
               )

      assert entry.name == "notes.md"
      assert File.read!(Path.join(root, "notes.md")) == "# notes"
    end

    test "update_document delegates", %{root: root} do
      document = seed_file(root, "guide.md", "old")

      assert {:ok, %{status: "updated"}} =
               handle(
                 %{"file_id" => document.source, "content" => "new"},
                 :update_document
               )

      assert File.read!(Path.join(root, "guide.md")) == "new"
    end

    test "delete_document delegates", %{root: root} do
      document = seed_file(root, "guide.md", "# guide")

      assert {:ok, %{status: "deleted"}} =
               handle(%{file_id: document.source}, :delete_document)

      refute File.exists?(Path.join(root, "guide.md"))
    end

    test "list_document_grants delegates", %{root: root} do
      document = seed_file(root, "guide.md", "# guide")

      assert {:ok, %{permissions: [], public?: false}} =
               handle(%{file_id: document.source}, :list_document_grants)
    end

    test "search_documents delegates", %{root: root} do
      document = seed_file(root, "quarterly.md", "# report")

      assert {:ok, %{entries: [entry]}} =
               handle(%{params: %{"query" => "quarterly"}}, :search_documents)

      assert entry.id == document.source
    end

    test "volume_stats delegates", %{root: root} do
      seed_file(root, "guide.md", "# guide")

      assert {:ok, %{files_count: 1, root_folders: [@volume]}} = handle(%{}, :volume_stats)
    end
  end

  describe "clause guards" do
    test "describe_document with a non-binary file_id falls through to the catch-all" do
      assert handle(%{file_id: 123}, :describe_document) ==
               {:error, {:unsupported_action, :describe_document}}
    end

    test "materialize_record with a non-binary file_id falls through to the catch-all" do
      assert handle(%{file_id: 123}, :materialize_record) ==
               {:error, {:unsupported_action, :materialize_record}}
    end

    test "delete_document with a non-binary file_id falls through to the catch-all" do
      assert handle(%{file_id: 123}, :delete_document) ==
               {:error, {:unsupported_action, :delete_document}}
    end

    test "list_document_grants with a non-binary file_id falls through to the catch-all" do
      assert handle(%{file_id: 123}, :list_document_grants) ==
               {:error, {:unsupported_action, :list_document_grants}}
    end

    test "list_documents with non-map params falls through to the catch-all" do
      assert handle(%{params: "nope"}, :list_documents) ==
               {:error, {:unsupported_action, :list_documents}}
    end

    test "search_documents with non-map params falls through to the catch-all" do
      assert handle(%{params: "nope"}, :search_documents) ==
               {:error, {:unsupported_action, :search_documents}}
    end

    test "a record action with a non-map request falls through to the catch-all" do
      assert handle(:not_a_map, :persist_document) ==
               {:error, {:unsupported_action, :persist_document}}

      assert handle(:not_a_map, :update_document) ==
               {:error, {:unsupported_action, :update_document}}

      assert handle(:not_a_map, :volume_stats) ==
               {:error, {:unsupported_action, :volume_stats}}
    end

    test "the catch-all stays last — every known action still resolves to its own clause" do
      # Clause order is load-bearing and silent when wrong: a catch-all placed above these
      # would swallow them all, and this assertion is what notices.
      actions = [
        {%{file_id: "1"}, :describe_document},
        {%{params: %{}}, :list_documents},
        {%{file_id: "99999999"}, :materialize_record},
        {%{}, :persist_document},
        {%{}, :update_document},
        {%{file_id: "99999999"}, :delete_document},
        {%{file_id: "99999999"}, :list_document_grants},
        {%{params: %{}}, :search_documents},
        {%{}, :volume_stats}
      ]

      for {request, action} <- actions do
        refute handle(request, action) == {:error, {:unsupported_action, action}},
               "#{action} fell through to the catch-all"
      end
    end
  end
end
