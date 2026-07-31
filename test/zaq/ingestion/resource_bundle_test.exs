defmodule Zaq.Ingestion.ResourceBundleTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Zaq.Contracts.Materialization
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Ingestion.BundleRecords
  alias Zaq.Ingestion.FileExplorer
  alias Zaq.Ingestion.ResourceBundle
  alias Zaq.Records.Content

  @test_base "test/tmp/resource_bundle"
  @locator ".agents/skills/pricing-faq"
  @text "# Pricing\n\nStandard tier is €40/month.\n"
  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xFE>>

  setup do
    File.rm_rf!(@test_base)

    alpha = Path.join(@test_base, "alpha")
    beta = Path.join(@test_base, "beta")
    File.mkdir_p!(alpha)
    File.mkdir_p!(beta)

    original = Application.get_env(:zaq, Zaq.Ingestion)

    Application.put_env(:zaq, Zaq.Ingestion,
      base_path: @test_base,
      volumes: %{"alpha" => alpha, "beta" => beta}
    )

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original || [])
      File.rm_rf!(@test_base)
    end)

    %{alpha: alpha, beta: beta}
  end

  defp write_resource(volume_root, type, name, content, locator \\ @locator) do
    dir = Path.join([volume_root, locator, type])
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  # The two fixtures the materialize describes share: one UTF-8, one binary.
  defp write_pair(alpha) do
    write_resource(alpha, "references", "pricing.md", @text)
    write_resource(alpha, "references", "logo.png", @png)
  end

  # The bundle comes off the descriptor, the file off `record.path` — the same split `list/1`
  # mints, so a fixture that got it wrong would not resemble anything materialize/1 ever sees.
  defp source(resource_path, opts \\ []) do
    %Record{
      id: "r",
      kind: :file,
      name: Path.basename(resource_path),
      path: resource_path,
      materialization:
        Materialization.new(:ingestion,
          params: %{locator: @locator},
          as: Keyword.get(opts, :as, :auto),
          max_bytes: Keyword.get(opts, :max_bytes)
        )
    }
  end

  # Param validation is not a separate callback — it is the function heads. These assert the
  # same refusals at the only place a caller can now reach them.
  defp descriptor(params, opts \\ []) do
    %Record{
      id: "r",
      kind: :file,
      name: "a.md",
      path: Keyword.get(opts, :path, "references/a.md"),
      materialization: Materialization.new(:ingestion, params: params)
    }
  end

  describe "list/1" do
    test "returns references entries for a bundle on a volume", %{alpha: alpha} do
      write_resource(alpha, "references", "pricing-2026.md", "# Pricing\n")

      assert {:ok, listing} = ResourceBundle.list(@locator)
      assert [entry] = listing.records

      assert entry.name == "pricing-2026.md"
      assert entry.path == "references/pricing-2026.md"
      assert entry.size == byte_size("# Pricing\n")
      assert %DateTime{} = entry.modified_at
      assert entry.materialization.role == :ingestion
    end

    # Type is carried by each record's `path`, not by a separate key, and list order is
    # references → assets → scripts so a truncated page loses the least useful entries first.
    test "orders entries by type, with the type carried in the path", %{alpha: alpha} do
      write_resource(alpha, "scripts", "setup.sh", "#!/bin/sh\n")
      write_resource(alpha, "assets", "logo.png", <<137, 80, 78, 71>>)
      write_resource(alpha, "references", "guide.md", "guide")

      assert {:ok, listing} = ResourceBundle.list(@locator)

      assert Enum.map(listing.records, & &1.path) == [
               "references/guide.md",
               "assets/logo.png",
               "scripts/setup.sh"
             ]
    end

    test "finds a bundle on the second volume without the caller naming it", %{beta: beta} do
      write_resource(beta, "references", "on-beta.md", "beta")

      assert {:ok, listing} = ResourceBundle.list(@locator)
      assert [%{name: "on-beta.md"}] = listing.records
    end

    test "missing locator returns an empty page, not an error" do
      assert {:ok, listing} = ResourceBundle.list(".agents/skills/never-uploaded")
      assert listing == BundleRecords.empty_page()
    end

    test "no volumes configured returns {:error, :no_volumes}" do
      Application.put_env(:zaq, Zaq.Ingestion, base_path: @test_base)

      assert {:error, :no_volumes} = ResourceBundle.list(@locator)
    end

    test "entries leak neither :absolute_path nor the volume name", %{alpha: alpha} do
      write_resource(alpha, "references", "pricing.md", "secret layout")

      assert {:ok, listing} = ResourceBundle.list(@locator)
      assert [entry] = listing.records

      refute Map.has_key?(entry, :absolute_path)

      # No value on the record may disclose the mount or the volume key — including inside
      # the descriptor, which is why this inspects the whole struct rather than a key list.
      serialized = inspect(entry)
      refute serialized =~ "alpha"
      refute serialized =~ "absolute_path"
      refute serialized =~ Path.expand(alpha)
    end

    test "the page itself names no volume", %{alpha: alpha} do
      write_resource(alpha, "references", "pricing.md", "body")

      assert {:ok, %RecordPage{} = listing} = ResourceBundle.list(@locator)
      assert listing.resource_type == :skill_bundle_file

      # The page wrapper carries counts and a resource type — nothing about where the bytes
      # physically are. `filters` and `metadata` stay empty rather than becoming a back door.
      assert listing.filters == %{}
      assert listing.metadata == %{}
      refute inspect(listing.pagination) =~ "alpha"
    end
  end

  describe "list/1 when the same locator exists on two volumes" do
    test "sorted-first volume wins, deterministically, and warns", %{alpha: alpha, beta: beta} do
      write_resource(alpha, "references", "from-alpha.md", "a")
      write_resource(beta, "references", "from-beta.md", "b")

      log =
        capture_log(fn ->
          assert {:ok, listing} = ResourceBundle.list(@locator)
          assert [%{name: "from-alpha.md"}] = listing.records
        end)

      assert log =~ "resolves on more than one volume"
      assert log =~ @locator

      # Deterministic across repeated calls — never dependent on Map.keys/1 ordering.
      for _ <- 1..5 do
        assert {:ok, %RecordPage{records: [%{name: "from-alpha.md"}]}} =
                 ResourceBundle.list(@locator)
      end
    end
  end

  describe "read_text/2" do
    test "returns the file's text", %{alpha: alpha} do
      write_resource(alpha, "references", "pricing.md", "# Pricing 2026\n")

      assert {:ok, "# Pricing 2026\n"} =
               ResourceBundle.read_text(@locator, "references/pricing.md")
    end

    test "reads from the second volume without the caller naming it", %{beta: beta} do
      write_resource(beta, "references", "on-beta.md", "beta body")

      assert {:ok, "beta body"} = ResourceBundle.read_text(@locator, "references/on-beta.md")
    end

    test "binary content returns {:error, :invalid_utf8}", %{alpha: alpha} do
      write_resource(alpha, "assets", "logo.png", <<137, 80, 78, 71, 0xFF, 0xFE>>)

      assert {:error, :invalid_utf8} = ResourceBundle.read_text(@locator, "assets/logo.png")
    end

    test "missing file returns {:error, :not_found}", %{alpha: alpha} do
      write_resource(alpha, "references", "present.md", "here")

      assert {:error, :not_found} = ResourceBundle.read_text(@locator, "references/absent.md")
    end

    test "missing bundle returns {:error, :not_found}" do
      assert {:error, :not_found} =
               ResourceBundle.read_text(".agents/skills/never-uploaded", "references/a.md")
    end

    test "no volumes configured returns {:error, :no_volumes}" do
      Application.put_env(:zaq, Zaq.Ingestion, base_path: @test_base)

      assert {:error, :no_volumes} = ResourceBundle.read_text(@locator, "references/a.md")
    end

    test "a bare filename is refused, not resolved against references/", %{alpha: alpha} do
      write_resource(alpha, "references", "pricing.md", "body")

      assert {:error, :invalid_resource_path} = ResourceBundle.read_text(@locator, "pricing.md")
    end

    test "an unknown type directory is refused", %{alpha: alpha} do
      dir = Path.join([alpha, @locator, "secrets"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "keys.txt"), "sk-live-1234")

      assert {:error, :invalid_resource_path} =
               ResourceBundle.read_text(@locator, "secrets/keys.txt")
    end
  end

  describe "security — the locator is untrusted" do
    test "traversal in the locator is refused" do
      assert {:error, :path_traversal} = ResourceBundle.list("../../etc")
      assert {:error, :path_traversal} = ResourceBundle.read_text("../../etc", "references/a.md")
    end

    test "a locator that only traverses on expansion is refused" do
      assert {:error, :path_traversal} = ResourceBundle.list(".agents/skills/../../../etc")
    end

    test "an absolute locator is refused" do
      assert {:error, :path_traversal} = ResourceBundle.list("/etc")
      assert {:error, :path_traversal} = ResourceBundle.read_text("/etc", "references/a.md")
    end

    test "a symlinked bundle root pointing outside the volume is refused", %{alpha: alpha} do
      outside = Path.join(@test_base, "outside")
      File.mkdir_p!(Path.join(outside, "references"))
      File.write!(Path.join([outside, "references", "stolen.md"]), "secret")

      link = Path.join(alpha, @locator)
      File.mkdir_p!(Path.dirname(link))
      :ok = File.ln_s(Path.expand(outside), link)

      assert {:ok, %RecordPage{records: []}} = ResourceBundle.list(@locator)

      assert {:error, reason} = ResourceBundle.read_text(@locator, "references/stolen.md")
      assert reason in [:not_found, :path_traversal]
    end

    test "a symlinked resource pointing outside the volume is not listed or read", %{alpha: alpha} do
      outside = Path.join(@test_base, "outside")
      File.mkdir_p!(outside)
      secret = Path.join(outside, "secret.md")
      File.write!(secret, "classified")

      write_resource(alpha, "references", "ok.md", "fine")
      link = Path.join([alpha, @locator, "references", "escape.md"])
      :ok = File.ln_s(Path.expand(secret), link)

      assert {:ok, listing} = ResourceBundle.list(@locator)
      assert Enum.map(listing.records, & &1.name) == ["ok.md"]

      assert {:error, reason} = ResourceBundle.read_text(@locator, "references/escape.md")
      assert reason in [:not_found, :path_traversal]
    end
  end

  describe "security — the resource path is untrusted" do
    setup %{alpha: alpha} do
      write_resource(alpha, "references", "ok.md", "fine")
      :ok
    end

    test "traversal in the resource path is refused" do
      assert {:error, reason} =
               ResourceBundle.read_text(@locator, "references/../../../etc/passwd")

      assert reason in [:path_traversal, :invalid_resource_path]
    end

    test "an absolute resource path is refused" do
      assert {:error, reason} = ResourceBundle.read_text(@locator, "/etc/passwd")
      assert reason in [:path_traversal, :invalid_resource_path]
    end

    test "a traversal disguised under a valid type directory is refused" do
      assert {:error, reason} =
               ResourceBundle.read_text(@locator, "references/../../../../etc/passwd")

      assert reason in [:path_traversal, :invalid_resource_path]
    end
  end

  describe "resolve_volume/1" do
    test "returns the volume holding the bundle", %{beta: beta} do
      write_resource(beta, "references", "a.md", "a")

      assert {:ok, "beta"} = ResourceBundle.resolve_volume(@locator)
    end

    test "returns :not_found when no volume holds it" do
      assert :not_found = ResourceBundle.resolve_volume(@locator)
    end

    test "returns {:error, :no_volumes} when none are configured" do
      Application.put_env(:zaq, Zaq.Ingestion, base_path: @test_base)

      assert {:error, :no_volumes} = ResourceBundle.resolve_volume(@locator)
    end

    test "refuses an unsafe locator" do
      assert {:error, :path_traversal} = ResourceBundle.resolve_volume("../../etc")
    end
  end

  describe "materialize/1 — descriptor refusals" do
    # Refused, not ignored: a caller that sent a volume has misunderstood the contract, and
    # dropping it silently teaches them the key works.
    test "a volume key is refused outright, on both key types" do
      atom_key = descriptor(%{locator: @locator, volume: "alpha"})
      string_key = descriptor(%{"volume" => "alpha", locator: @locator})

      assert {:error, :volume_not_addressable} = ResourceBundle.materialize(atom_key)
      assert {:error, :volume_not_addressable} = ResourceBundle.materialize(string_key)
    end

    test "a missing locator is refused" do
      assert {:error, :invalid_params} = ResourceBundle.materialize(descriptor(%{}))
    end

    test "a record with a locator but no path is refused" do
      assert {:error, :invalid_params} =
               ResourceBundle.materialize(descriptor(%{locator: @locator}, path: nil))
    end

    # What the registry, and then the tag, used to refuse. A descriptor belonging to other
    # storage must not be run here just because it arrived at this role — its params are
    # shaped for its own reader and carry no locator, so this head never matches.
    test "a descriptor belonging to other storage is refused rather than run" do
      foreign = descriptor(%{id: "mattermost-attachment-1"})

      assert {:error, :invalid_params} = ResourceBundle.materialize(foreign)
    end

    test "a record with no descriptor at all is refused without reading" do
      assert {:error, :invalid_params} =
               ResourceBundle.materialize(%Record{id: "r", kind: :file, name: "a.md"})
    end
  end

  describe "materialize/1 — the acceptance matrix" do
    setup %{alpha: alpha}, do: write_pair(alpha) && :ok

    test "as: :auto returns UTF-8 as text" do
      assert {:ok, record} = ResourceBundle.materialize(source("references/pricing.md"))

      assert record.content == @text
      assert record.attributes["encoding"] == "utf8"
    end

    test "as: :auto returns a binary as base64 that round-trips exactly" do
      assert {:ok, record} = ResourceBundle.materialize(source("references/logo.png"))

      assert record.attributes["encoding"] == "base64"
      assert {:ok, @png} = Content.decode(record)
    end

    test "as: :text refuses a binary rather than encoding it" do
      assert {:error, :invalid_utf8} =
               ResourceBundle.materialize(source("references/logo.png", as: :text))
    end

    test "as: :binary encodes even text" do
      assert {:ok, record} =
               ResourceBundle.materialize(source("references/pricing.md", as: :binary))

      assert record.attributes["encoding"] == "base64"
      assert {:ok, @text} = Content.decode(record)
    end

    test "size is the raw byte count, not the encoded length" do
      assert {:ok, record} = ResourceBundle.materialize(source("references/logo.png"))

      assert record.size == byte_size(@png)
      assert byte_size(record.content) > byte_size(@png)
    end
  end

  describe "materialize/1 — the size cap" do
    setup %{alpha: alpha}, do: write_pair(alpha) && :ok

    test "refuses over max_bytes and does not read the file" do
      assert {:error, {:too_large, size}} =
               ResourceBundle.materialize(source("references/pricing.md", max_bytes: 4))

      assert size == byte_size(@text)
    end

    test "allows a file at exactly the cap" do
      assert {:ok, _record} =
               ResourceBundle.materialize(
                 source("references/pricing.md", max_bytes: byte_size(@text))
               )
    end

    test "no cap means no check" do
      assert {:ok, _record} = ResourceBundle.materialize(source("references/pricing.md"))
    end
  end

  describe "materialize/1 — refusals and leak guards" do
    setup %{alpha: alpha}, do: write_pair(alpha) && :ok

    test "a missing file is not found" do
      assert {:error, :not_found} = ResourceBundle.materialize(source("references/absent.md"))
    end

    test "traversal and absolute paths are refused" do
      assert {:error, _} = ResourceBundle.materialize(source("../../../etc/passwd"))
      assert {:error, _} = ResourceBundle.materialize(source("/etc/passwd"))
    end

    test "a bare filename with no type prefix is refused rather than guessed at" do
      assert {:error, :invalid_resource_path} = ResourceBundle.materialize(source("pricing.md"))
    end

    test "no absolute path or volume name appears on a materialized record" do
      {:ok, record} = ResourceBundle.materialize(source("references/pricing.md"))
      serialized = inspect(record)

      refute serialized =~ Path.expand(@test_base)
      refute serialized =~ "alpha"
      refute serialized =~ "absolute_path"
    end
  end

  # `record.path` stops being display metadata and becomes an input to materialization. That
  # coupling is load-bearing, so it is pinned rather than left implied by the fixtures.
  describe "materialize/1 — the path comes off the record" do
    setup %{alpha: alpha}, do: write_pair(alpha) && :ok

    test "reads the file the record names, not one the descriptor names" do
      # A descriptor carrying a stale `resource_path` must not be consulted: the record's own
      # path is the address, and the extra key is inert rather than an override.
      record = %Record{
        source("references/pricing.md")
        | materialization:
            Materialization.new(:ingestion,
              params: %{locator: @locator, resource_path: "references/logo.png"}
            )
      }

      assert {:ok, materialized} = ResourceBundle.materialize(record)
      assert materialized.content == @text
    end

    test "a tampered path is refused exactly as a caller-supplied one is" do
      for tampered <- [
            "../../../etc/passwd",
            "/etc/passwd",
            "references/../../other-skill/references/salaries.md",
            "pricing.md"
          ] do
        assert {:error, reason} = ResourceBundle.materialize(source(tampered))
        assert reason in [:path_traversal, :invalid_resource_path]
      end
    end

    # The isolation boundary: the locator is what confines a read to one bundle, and no path
    # on the record can reach past it into a sibling skill's files.
    test "a path cannot reach another skill's bundle inside the same volume", %{alpha: alpha} do
      write_resource(alpha, "references", "salaries.md", "CONFIDENTIAL", ".agents/skills/hr")

      assert {:error, reason} =
               ResourceBundle.materialize(source("references/../../hr/references/salaries.md"))

      assert reason in [:path_traversal, :invalid_resource_path]
    end
  end

  describe "property: containment" do
    property "no locator/resource_path pair ever reads outside a volume root", %{alpha: alpha} do
      write_resource(alpha, "references", "ok.md", "fine")
      roots = @test_base |> Path.expand() |> Path.join("alpha")

      segment =
        StreamData.one_of([
          StreamData.constant(".."),
          StreamData.constant("."),
          StreamData.constant("references"),
          StreamData.constant("etc"),
          StreamData.string(:alphanumeric, min_length: 1, max_length: 6)
        ])

      check all(
              locator_parts <- StreamData.list_of(segment, min_length: 1, max_length: 5),
              resource_parts <- StreamData.list_of(segment, min_length: 1, max_length: 5),
              max_runs: 200
            ) do
        locator = Enum.join(locator_parts, "/")
        resource_path = Enum.join(resource_parts, "/")

        case ResourceBundle.read_text(locator, resource_path) do
          {:ok, _text} ->
            # A successful read must have come from inside the volume that holds it.
            assert {:ok, volume} = ResourceBundle.resolve_volume(locator)
            assert volume in ["alpha", "beta"]

            assert {:ok, absolute} =
                     FileExplorer.resolve_path(
                       volume,
                       Path.join(locator, resource_path)
                     )

            assert String.starts_with?(absolute, roots <> "/") or
                     String.starts_with?(
                       absolute,
                       Path.expand(Path.join(@test_base, "beta")) <> "/"
                     )

          {:error, _reason} ->
            :ok
        end
      end
    end
  end
end
