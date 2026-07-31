defmodule Zaq.Ingestion.ResourceBundleTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Zaq.Ingestion.FileExplorer
  alias Zaq.Ingestion.ResourceBundle

  @test_base "test/tmp/resource_bundle"
  @locator ".agents/skills/pricing-faq"

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

  describe "list/1" do
    test "returns references entries for a bundle on a volume", %{alpha: alpha} do
      write_resource(alpha, "references", "pricing-2026.md", "# Pricing\n")

      assert {:ok, listing} = ResourceBundle.list(@locator)
      assert [entry] = listing.references

      assert entry.name == "pricing-2026.md"
      assert entry.path == "references/pricing-2026.md"
      assert entry.size == byte_size("# Pricing\n")
      assert %DateTime{} = entry.modified_at
      assert entry.materialization.strategy == :skill_bundle
    end

    test "groups entries by type", %{alpha: alpha} do
      write_resource(alpha, "references", "guide.md", "guide")
      write_resource(alpha, "assets", "logo.png", <<137, 80, 78, 71>>)
      write_resource(alpha, "scripts", "setup.sh", "#!/bin/sh\n")

      assert {:ok, listing} = ResourceBundle.list(@locator)

      assert [%{path: "references/guide.md"}] = listing.references
      assert [%{path: "assets/logo.png"}] = listing.assets
      assert [%{path: "scripts/setup.sh"}] = listing.scripts
    end

    test "finds a bundle on the second volume without the caller naming it", %{beta: beta} do
      write_resource(beta, "references", "on-beta.md", "beta")

      assert {:ok, listing} = ResourceBundle.list(@locator)
      assert [%{name: "on-beta.md"}] = listing.references
    end

    test "missing locator returns an empty listing, not an error" do
      assert {:ok, listing} = ResourceBundle.list(".agents/skills/never-uploaded")
      assert listing == %{references: [], assets: [], scripts: []}
    end

    test "no volumes configured returns {:error, :no_volumes}" do
      Application.put_env(:zaq, Zaq.Ingestion, base_path: @test_base)

      assert {:error, :no_volumes} = ResourceBundle.list(@locator)
    end

    test "entries leak neither :absolute_path nor the volume name", %{alpha: alpha} do
      write_resource(alpha, "references", "pricing.md", "secret layout")

      assert {:ok, listing} = ResourceBundle.list(@locator)
      assert [entry] = listing.references

      refute Map.has_key?(entry, :absolute_path)

      # No value on the record may disclose the mount or the volume key — including inside
      # the descriptor, which is why this inspects the whole struct rather than a key list.
      serialized = inspect(entry)
      refute serialized =~ "alpha"
      refute serialized =~ "absolute_path"
      refute serialized =~ Path.expand(alpha)
    end

    test "the listing itself names no volume", %{alpha: alpha} do
      write_resource(alpha, "references", "pricing.md", "body")

      assert {:ok, listing} = ResourceBundle.list(@locator)
      assert Map.keys(listing) |> Enum.sort() == [:assets, :references, :scripts]
    end
  end

  describe "list/1 when the same locator exists on two volumes" do
    test "sorted-first volume wins, deterministically, and warns", %{alpha: alpha, beta: beta} do
      write_resource(alpha, "references", "from-alpha.md", "a")
      write_resource(beta, "references", "from-beta.md", "b")

      log =
        capture_log(fn ->
          assert {:ok, listing} = ResourceBundle.list(@locator)
          assert [%{name: "from-alpha.md"}] = listing.references
        end)

      assert log =~ "resolves on more than one volume"
      assert log =~ @locator

      # Deterministic across repeated calls — never dependent on Map.keys/1 ordering.
      for _ <- 1..5 do
        assert {:ok, %{references: [%{name: "from-alpha.md"}]}} = ResourceBundle.list(@locator)
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

      assert {:ok, %{references: []}} = ResourceBundle.list(@locator)

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
      assert Enum.map(listing.references, & &1.name) == ["ok.md"]

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
