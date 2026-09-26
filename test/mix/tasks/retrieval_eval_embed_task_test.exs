defmodule Mix.Tasks.RetrievalEval.EmbedTaskTest do
  use Zaq.DataCase, async: false

  alias Mix.Tasks.Retrieval.Eval.Embed, as: EmbedTask
  alias Mix.Tasks.RetrievalEval.Fixtures
  alias Zaq.System, as: SystemConfig
  alias Zaq.SystemConfigFixtures

  @default_root Fixtures.default_path()

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(previous_shell) end)

    SystemConfigFixtures.seed_embedding_config(%{model: "test-model", dimension: 2})
    :ok
  end

  test "rejects positional arguments before producing output or touching fixtures" do
    with_fixture_copy(fn root ->
      before = fixture_bytes(root)

      assert_raise Mix.Error, ~r/Unexpected arguments: \["surplus"\]/, fn ->
        run_task(["--path", root, "surplus"])
      end

      assert fixture_bytes(root) == before
      refute_received {:mix_shell, _, _}
    end)
  end

  test "rejects unknown options" do
    with_fixture_copy(fn root ->
      assert_raise OptionParser.ParseError, fn ->
        run_task(["--unknown", "--path", root])
      end

      refute_received {:mix_shell, _, _}
    end)
  end

  test "fails fast for an empty model and zero dimension without provider calls or writes" do
    with_fixture_copy(fn root ->
      before = fixture_bytes(root)
      reject_config(root, "embedding.model", "")
      {:ok, _} = SystemConfig.set_config("embedding.model", "test-model")
      reject_config(root, "embedding.dimension", "0")
      assert fixture_bytes(root) == before
    end)
  end

  test "prepares missing embeddings through the configured HTTP client and is idempotent" do
    with_fixture_copy(fn root ->
      stub_embeddings(self(), [1.0, 0.0])
      before = fixture_bytes(root)

      assert :ok == run_task(["--path", root])
      assert_received {:mix_shell, :info, [summary]}
      assert [embedded, updated] = summary_counts(summary)
      assert embedded > 0 and updated > 0
      changed = changed_paths(before, fixture_bytes(root))
      assert length(changed) == updated
      assert_received_paths(changed)

      %{documents: docs, questions: [question]} = Fixtures.load!(root, :prepare)
      assert_provenance_and_vectors(docs, question, "test-model", [1.0, 0.0])
      question_before = Jason.decode!(before[Path.join(root, "questions/english-travel.json")])
      assert question.data["question"] == question_before["question"]
      assert question.data["expected"] == question_before["expected"]
      assert question.data["forbidden"] == question_before["forbidden"]
      assert length(receive_embedding_inputs()) == embedded

      populated = fixture_bytes(root)
      stub_no_embeddings()
      assert :ok == run_task(["--path", root])

      assert_received {:mix_shell, :info,
                       ["Prepared 0 unique input embeddings; updated 0 fixture files"]}

      refute_received {:mix_shell, :info, [_]}
      assert fixture_bytes(root) == populated
      assert receive_embedding_inputs() == []
    end)
  end

  test "refresh replaces vectors while preserving authored question relevance" do
    with_fixture_copy(fn root ->
      Req.Test.stub(Zaq.Embedding.Client, fn conn ->
        Req.Test.json(conn, %{"data" => [%{"embedding" => [1.0, 0.0]}]})
      end)

      run_task(["--path", root])
      assert_received {:mix_shell, :info, [_]}
      flush_shell_info()
      _ = receive_embedding_inputs()

      before_refresh = fixture_bytes(root)

      question_before =
        Jason.decode!(before_refresh[Path.join(root, "questions/english-travel.json")])

      stub_embeddings(self(), [0.0, 1.0])

      assert :ok == run_task(["--path", root, "--refresh"])
      assert_received {:mix_shell, :info, [summary]}
      [embedded, updated] = summary_counts(summary)
      assert embedded > 0 and updated > 0
      changed = changed_paths(before_refresh, fixture_bytes(root))
      assert length(changed) == updated
      assert_received_paths(changed)

      %{documents: docs, questions: [question]} = Fixtures.load!(root, :prepare)
      assert_provenance_and_vectors(docs, question, "test-model", [0.0, 1.0])
      assert question.data["question"] == question_before["question"]
      assert question.data["expected"] == question_before["expected"]
      assert question.data["forbidden"] == question_before["forbidden"]
      assert length(receive_embedding_inputs()) == embedded
    end)
  end

  test "default path is a compatible, complete no-op and leaves every fixture byte unchanged" do
    SystemConfigFixtures.seed_embedding_config(%{
      model: "bge-multilingual-gemma2",
      dimension: 3584
    })

    %{embedding_space: {"bge-multilingual-gemma2", 3584}} =
      fixtures =
      Fixtures.load!(@default_root, :prepare)

    embedded_items =
      Enum.flat_map(fixtures.documents, fn document ->
        document.data["chunks"]
      end) ++
        Enum.flat_map(fixtures.questions, fn question ->
          Map.values(question.data["variants"])
        end)

    assert embedded_items != []

    assert Enum.all?(embedded_items, fn item ->
             is_list(item["embedding"]) and is_map(item["embedding_provenance"]) and
               item["embedding_provenance"]["model"] == "bge-multilingual-gemma2" and
               item["embedding_provenance"]["dimension"] == 3584
           end)

    before = fixture_bytes(@default_root)

    Req.Test.stub(Zaq.Embedding.Client, fn _conn ->
      flunk("default fixtures are complete; embedding provider must not be called")
    end)

    assert :ok == run_task([])

    assert_received {:mix_shell, :info,
                     ["Prepared 0 unique input embeddings; updated 0 fixture files"]}

    refute_received {:mix_shell, :info, [_]}
    assert fixture_bytes(@default_root) == before
  end

  defp run_task(args) do
    Mix.Task.reenable("retrieval.eval.embed")
    EmbedTask.run(args)
  end

  defp reject_config(root, key, value) do
    {:ok, _} = SystemConfig.set_config(key, value)

    Req.Test.stub(Zaq.Embedding.Client, fn _conn ->
      flunk("invalid embedding configuration must fail before provider calls")
    end)

    assert_raise Mix.Error,
                 ~r/Configure the embedding model, dimension and provider endpoint in ZAQ/,
                 fn -> run_task(["--path", root]) end

    refute_received {:mix_shell, _, _}
  end

  defp with_fixture_copy(fun) do
    root =
      Path.join(
        Elixir.System.tmp_dir!(),
        "retrieval_embed_task_#{Elixir.System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "documents"))
    File.mkdir_p!(Path.join(root, "questions"))

    for {kind, name} <- [
          {"documents", "english-travel"},
          {"documents", "french-equipment"},
          {"documents", "arabic-leave"},
          {"questions", "english-travel"}
        ] do
      source = Path.join([@default_root, kind, "#{name}.json"])
      destination = Path.join([root, kind, "#{name}.json"])
      File.cp!(source, destination)
      clear_embeddings(destination, kind)
    end

    on_exit(fn -> File.rm_rf!(root) end)
    fun.(root)
  end

  defp clear_embeddings(path, "documents") do
    data = path |> File.read!() |> Jason.decode!()

    data =
      Map.update!(data, "chunks", fn chunks ->
        Enum.map(chunks, &Map.merge(&1, %{"embedding" => nil, "embedding_provenance" => nil}))
      end)

    File.write!(path, Jason.encode!(data))
  end

  defp clear_embeddings(path, "questions") do
    data = path |> File.read!() |> Jason.decode!()

    data =
      data
      |> Map.put("forbidden", [])
      |> Map.update!("variants", fn variants ->
        Map.new(variants, fn {language, variant} ->
          {language, Map.merge(variant, %{"embedding" => nil, "embedding_provenance" => nil})}
        end)
      end)

    File.write!(path, Jason.encode!(data))
  end

  defp fixture_bytes(root) do
    for kind <- ~w(documents questions),
        path <- Path.wildcard(Path.join(root, "#{kind}/*.json")),
        into: %{},
        do: {path, File.read!(path)}
  end

  defp stub_embeddings(test_pid, vector) do
    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["model"] == "test-model"
      send(test_pid, {:embedding_input, request["input"]})
      Req.Test.json(conn, %{"data" => [%{"embedding" => vector}]})
    end)
  end

  defp receive_embedding_inputs(inputs \\ []) do
    receive do
      {:embedding_input, input} -> receive_embedding_inputs([input | inputs])
    after
      0 -> Enum.reverse(inputs)
    end
  end

  defp stub_no_embeddings do
    Req.Test.stub(Zaq.Embedding.Client, fn _conn ->
      flunk("complete embeddings must not be requested")
    end)
  end

  defp summary_counts("Prepared " <> rest) do
    [embedded, updated] =
      Regex.run(~r/^(\d+) unique input embeddings; updated (\d+) fixture files$/, rest,
        capture: :all_but_first
      )

    Enum.map([embedded, updated], &String.to_integer/1)
  end

  defp changed_paths(before, after_bytes) do
    before
    |> Enum.filter(fn {path, bytes} -> Map.fetch!(after_bytes, path) != bytes end)
    |> Enum.map(&elem(&1, 0))
  end

  defp assert_received_paths(paths) do
    Enum.each(paths, fn path -> assert_received {:mix_shell, :info, [^path]} end)
    refute_received {:mix_shell, :info, [_]}
  end

  defp assert_provenance_and_vectors(docs, question, model, vector) do
    entries =
      Enum.flat_map(docs, fn doc ->
        Enum.map(doc.data["chunks"], &{&1, &1["content"]})
      end)

    entries =
      entries ++
        Enum.map(question.data["variants"], fn {_lang, variant} ->
          {variant, variant["semantic_query"]}
        end)

    assert entries != []

    Enum.each(entries, fn {item, text} ->
      assert item["embedding"] == vector

      assert %{"model" => ^model, "dimension" => 2, "input_sha256" => input_hash} =
               item["embedding_provenance"]

      assert input_hash == Fixtures.input_hash(text)
    end)
  end

  defp flush_shell_info do
    receive do
      {:mix_shell, :info, _} -> flush_shell_info()
    after
      0 -> :ok
    end
  end
end
