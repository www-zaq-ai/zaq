defmodule Zaq.Agent.SkillReferenceE2ETest do
  @moduledoc """
  End-to-end: an agent tool asking for a skill reference by id, and getting the bytes back.

  Nothing on the path under test is stubbed. A real file on a real volume, a real document
  row, the real `disk` provider resolved from `config.exs`, and the real modules at every
  hop:

      DownloadDocument.run/2
        → Materializer.materialize/2
        → Channels.Api  → DataSourceBridge → DiskBridge
        → Ingestion.Api → RecordMaterializer → DocumentAccess → File.read/1

  Only the transport between roles is short-circuited, which is what `NodeRouter` would
  otherwise do over the network.
  """

  use Zaq.DataCase, async: false

  import Ecto.Query
  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Tools.DataSource.DownloadDocument
  alias Zaq.Agent.Tools.Skills.LoadSkill
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.DataSourceBridge
  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.RecordMaterializer
  alias Zaq.Repo

  @volume "e2evol"

  # Routes each hop to the real role API, re-injecting itself so the bridge's own dispatch
  # to ingestion comes back here instead of reaching the real NodeRouter.
  defmodule RealRouter do
    @channels [:data_source_download_document, :data_source_create_file, :data_source_list_files]
    @ingestion [:materialize_record, :persist_record, :describe_records, :delete_record]

    def dispatch(%{opts: opts} = event) do
      case Keyword.get(opts, :action) do
        action when action in @channels -> channels(event, action)
        action when action in @ingestion -> Zaq.Ingestion.Api.handle_event(event, action, nil)
      end
    end

    defp channels(%{request: %{provider: provider, params: params}} = event, action) do
      request = %{provider: provider, params: Map.put(params, "node_router", __MODULE__)}
      Zaq.Channels.Api.handle_event(%{event | request: request}, action, nil)
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "zaq-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous = Application.get_env(:zaq, Zaq.Ingestion, [])
    Application.put_env(:zaq, Zaq.Ingestion, Keyword.put(previous, :volumes, %{@volume => root}))

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, previous)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp write_reference(content, tags) do
    {:ok, %Record{} = record} =
      RecordMaterializer.persist(%{
        volume: @volume,
        path: ".agents/skills/pricing-faq/references/prices.md",
        content: content,
        tags: tags
      })

    record
  end

  test "an agent downloads a public skill reference and gets its bytes", %{root: root} do
    record = write_reference("# Q3 prices\n42", ["public"])

    # The file really is on the volume, at the derived path.
    assert File.exists?(Path.join(root, ".agents/skills/pricing-faq/references/prices.md"))

    assert {:ok, %{record: materialized}} =
             DownloadDocument.run(
               %{provider: "disk", document_id: record.id},
               %{node_router: RealRouter}
             )

    assert materialized.content == "# Q3 prices\n42"
    assert materialized.name == "prices.md"
    assert materialized.id == record.id
    # The tool projects to a plain map of public fields, so the spent event and the
    # provider-internal `raw` are absent rather than merely nil.
    refute Map.has_key?(materialized, :materializing_event)
    refute Map.has_key?(materialized, :raw)
  end

  # The rail, exercised through the whole chain rather than against DocumentAccess directly:
  # an agent with no person behind it gets nothing but public documents.
  test "the same round trip is refused for a document that is not public" do
    record = write_reference("classified", [])

    assert {:error, message} =
             DownloadDocument.run(
               %{provider: "disk", document_id: record.id},
               %{node_router: RealRouter}
             )

    assert message =~ "Data source document download failed"
    assert message =~ "forbidden"
  end

  test "a reference whose document was deleted reports not_found, not a crash" do
    record = write_reference("temporary", ["public"])
    :ok = RecordMaterializer.delete(%{file_id: record.id})

    assert {:error, message} =
             DownloadDocument.run(
               %{provider: "disk", document_id: record.id},
               %{node_router: RealRouter}
             )

    assert message =~ "not_found"
  end

  test "an empty reference file round-trips as empty content, not as an error" do
    record = write_reference("", ["public"])

    assert {:ok, %{record: %{content: ""}}} =
             DownloadDocument.run(
               %{provider: "disk", document_id: record.id},
               %{node_router: RealRouter}
             )
  end

  test "listing references returns unmaterialized records" do
    first = write_reference("one", ["public"])
    second = write_reference("two", ["public"])

    {:ok, page} =
      DataSourceBridge.list_files("disk", %{
        "file_ids" => [first.id, second.id],
        "node_router" => RealRouter
      })

    assert length(page.records) == 2
    # Metadata travels; bytes do not, until something asks for them.
    assert Enum.all?(page.records, &is_nil(&1.content))
    # Both were written under the same requested filename; the second was de-duplicated
    # rather than clobbering the first, so the names differ and both still resolve.
    assert Enum.all?(page.records, &String.ends_with?(&1.name, ".md"))
    assert page.records |> Enum.map(& &1.name) |> Enum.uniq() |> length() == 2
  end

  # The handoff the model actually performs: read a skill, pick a listed file, download it
  # using the `provider` and `id` that listing gave. Regression for a model inventing a
  # provider ("internal") because `load_skill` withheld the real one.
  test "the whole agent path — load_skill then download_document with what it returned" do
    record = write_reference("# The referenced content", ["public"])

    {:ok, skill} =
      Skills.create_skill(%{
        name: "pricing-faq",
        description: "Answers pricing questions.",
        body: "Consult the attached price list.",
        resources: %{"references" => [%{"file_id" => record.id, "provider" => "disk"}]}
      })

    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, agent} =
      Agent.create_agent(%{
        name: "assistant-#{System.unique_integer([:positive])}",
        job: "Help.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        active: true,
        enabled_tool_keys: [],
        enabled_skill_ids: [skill.id]
      })

    context = %{configured_agent_id: agent.id, node_router: RealRouter}

    assert {:ok, loaded} = LoadSkill.run(%{name: "pricing-faq"}, context)
    assert [%{id: id, name: name, provider: provider}] = loaded.resources
    assert name == "prices.md"

    # Nothing is substituted here — exactly the values the model was handed go back in.
    assert {:ok, %{record: %{content: content}}} =
             DownloadDocument.run(%{provider: provider, document_id: id}, context)

    assert content == "# The referenced content"
  end

  test "the disk provider needs no channel_configs row" do
    assert Repo.aggregate(from(c in ChannelConfig, where: c.provider == "disk"), :count) == 0

    record = write_reference("still works", ["public"])

    assert {:ok, _} =
             DownloadDocument.run(
               %{provider: "disk", document_id: record.id},
               %{node_router: RealRouter}
             )
  end
end
