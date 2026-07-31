defmodule Zaq.Ingestion.Records.SkillBundleStrategyTest do
  use ExUnit.Case, async: false

  alias Zaq.Agent.Skills.Limits
  alias Zaq.Contracts.Materialization
  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.Records.SkillBundleStrategy, as: Strategy
  alias Zaq.Records.Content

  @base "test/tmp/skill_bundle_strategy"
  @locator ".agents/skills/pricing-faq"
  @text "# Pricing\n\nStandard tier is €40/month.\n"
  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xFE>>

  setup do
    File.rm_rf!(@base)
    alpha = Path.join(@base, "alpha")
    references = Path.join([alpha, @locator, "references"])
    File.mkdir_p!(references)
    File.write!(Path.join(references, "pricing.md"), @text)
    File.write!(Path.join(references, "logo.png"), @png)

    original = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, base_path: @base, volumes: %{"alpha" => alpha})

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original || [])
      File.rm_rf!(@base)
    end)

    %{alpha: alpha}
  end

  defp source(resource_path, opts \\ []) do
    %Record{
      id: "r",
      kind: :file,
      name: Path.basename(resource_path),
      materialization:
        Materialization.new(:ingestion, :skill_bundle,
          params: %{locator: @locator, resource_path: resource_path},
          as: Keyword.get(opts, :as, :auto),
          max_bytes: Keyword.get(opts, :max_bytes)
        )
    }
  end

  defp destination(name, bytes, opts \\ []) do
    {:ok, record} =
      %Record{
        id: "new",
        kind: :file,
        name: name,
        materialization:
          Materialization.new(:ingestion, :skill_bundle,
            params: %{locator: @locator, purpose: Keyword.get(opts, :purpose, :asset)}
          )
      }
      |> Content.put(bytes, :auto)

    record
  end

  describe "capabilities and params" do
    test "declares both verbs" do
      assert Strategy.capabilities() == [:materialize, :persist]
    end

    test "accepts a read descriptor and a write descriptor" do
      assert :ok =
               Strategy.validate_params(%{locator: @locator, resource_path: "references/a.md"})

      assert :ok = Strategy.validate_params(%{locator: @locator, purpose: :asset})
    end

    # Refused, not ignored: a caller that sent a volume has misunderstood the contract, and
    # dropping it silently teaches them the key works.
    test "refuses a volume key outright" do
      assert {:error, :volume_not_addressable} =
               Strategy.validate_params(%{locator: @locator, resource_path: "a", volume: "alpha"})

      assert {:error, :volume_not_addressable} =
               Strategy.validate_params(%{"volume" => "alpha", locator: @locator})
    end

    test "refuses an unknown purpose and a missing locator" do
      assert {:error, :invalid_params} =
               Strategy.validate_params(%{locator: @locator, purpose: :script})

      assert {:error, :invalid_params} =
               Strategy.validate_params(%{resource_path: "references/a.md"})

      assert {:error, :invalid_params} = Strategy.validate_params(%{})
    end
  end

  describe "materialize — the acceptance matrix" do
    test "as: :auto returns UTF-8 as text" do
      assert {:ok, record} = Strategy.materialize(source("references/pricing.md"), [])

      assert record.content == @text
      assert record.attributes["encoding"] == "utf8"
    end

    test "as: :auto returns a binary as base64 that round-trips exactly" do
      assert {:ok, record} = Strategy.materialize(source("references/logo.png"), [])

      assert record.attributes["encoding"] == "base64"
      assert {:ok, @png} = Content.decode(record)
    end

    test "as: :text refuses a binary rather than encoding it" do
      assert {:error, :invalid_utf8} =
               Strategy.materialize(source("references/logo.png", as: :text), [])
    end

    test "as: :binary encodes even text" do
      assert {:ok, record} =
               Strategy.materialize(source("references/pricing.md", as: :binary), [])

      assert record.attributes["encoding"] == "base64"
      assert {:ok, @text} = Content.decode(record)
    end

    test "size is the raw byte count, not the encoded length" do
      assert {:ok, record} = Strategy.materialize(source("references/logo.png"), [])

      assert record.size == byte_size(@png)
      assert byte_size(record.content) > byte_size(@png)
    end
  end

  describe "materialize — the size cap" do
    test "refuses over max_bytes and does not read the file" do
      assert {:error, {:too_large, size}} =
               Strategy.materialize(source("references/pricing.md", max_bytes: 4), [])

      assert size == byte_size(@text)
    end

    test "allows a file at exactly the cap" do
      assert {:ok, _record} =
               Strategy.materialize(
                 source("references/pricing.md", max_bytes: byte_size(@text)),
                 []
               )
    end

    test "no cap means no check" do
      assert {:ok, _record} = Strategy.materialize(source("references/pricing.md"), [])
    end
  end

  describe "materialize — refusals" do
    test "a missing file is not found" do
      assert {:error, :not_found} = Strategy.materialize(source("references/absent.md"), [])
    end

    test "traversal and absolute paths are refused" do
      assert {:error, _} = Strategy.materialize(source("../../../etc/passwd"), [])
      assert {:error, _} = Strategy.materialize(source("/etc/passwd"), [])
    end

    test "a bare filename with no type prefix is refused rather than guessed at" do
      assert {:error, :invalid_resource_path} = Strategy.materialize(source("pricing.md"), [])
    end
  end

  describe "persist" do
    test "writes the bytes and returns a handle, not the content" do
      assert {:ok, handle} = Strategy.persist(destination("chart.png", @png), [])

      assert handle.content == nil
      assert handle.path == "assets/chart.png"
      assert handle.size == byte_size(@png)
      assert handle.materialization.params.resource_path == "assets/chart.png"
    end

    # The round-trip is the real test of the contract: the output of a write is the input of
    # a read.
    test "the returned handle materializes back to the exact bytes" do
      {:ok, handle} = Strategy.persist(destination("chart.png", @png), [])

      assert {:ok, materialized} = Strategy.materialize(handle, [])
      assert {:ok, @png} = Content.decode(materialized)
    end

    test "text round-trips too" do
      {:ok, handle} = Strategy.persist(destination("notes.md", @text, purpose: :reference), [])

      assert handle.path == "references/notes.md"
      assert {:ok, materialized} = Strategy.materialize(handle, [])
      assert materialized.content == @text
    end

    test "a name collision is deduped, not overwritten, and the handle names the real file" do
      {:ok, first} = Strategy.persist(destination("chart.png", @png), [])
      {:ok, second} = Strategy.persist(destination("chart.png", "different"), [])

      refute first.path == second.path
      assert {:ok, original} = Strategy.materialize(first, [])
      assert {:ok, @png} = Content.decode(original)
    end

    # The name arrives on a caller-supplied record, so it must not be able to steer the write.
    test "a name carrying directory separators cannot escape its purpose directory" do
      {:ok, handle} = Strategy.persist(destination("../../../etc/passwd", "pwned"), [])

      assert handle.path == "assets/passwd"
      refute File.exists?("/etc/passwd.tmp")
    end

    test "refuses a record with no content" do
      record = %Record{
        id: "x",
        kind: :file,
        name: "empty.png",
        materialization:
          Materialization.new(:ingestion, :skill_bundle,
            params: %{locator: @locator, purpose: :asset}
          )
      }

      assert {:error, :no_content} = Strategy.persist(record, [])
    end

    test "refuses bytes over the upload cap" do
      oversize = :binary.copy("a", Limits.get(:resource_max_bytes) + 1)

      assert {:error, {:too_large, _size}} =
               Strategy.persist(destination("big.bin", oversize), [])
    end
  end

  describe "leak guards" do
    test "no absolute path or volume name appears on a materialized record" do
      {:ok, record} = Strategy.materialize(source("references/pricing.md"), [])
      serialized = inspect(record)

      refute serialized =~ Path.expand(@base)
      refute serialized =~ "alpha"
      refute serialized =~ "absolute_path"
    end

    test "no absolute path or volume name appears on a persisted handle" do
      {:ok, handle} = Strategy.persist(destination("chart.png", @png), [])
      serialized = inspect(handle)

      refute serialized =~ Path.expand(@base)
      refute serialized =~ "alpha"
    end
  end

  describe "containment property" do
    @tag :property
    test "no generated locator and resource_path pair escapes the volume" do
      segments = ["..", ".", "references", "assets", "etc", "passwd", "a b", "..%2f", ""]

      for _ <- 1..60 do
        locator = Enum.map_join(1..Enum.random(1..3), "/", fn _ -> Enum.random(segments) end)
        path = Enum.map_join(1..Enum.random(1..3), "/", fn _ -> Enum.random(segments) end)

        record = %Record{
          id: "p",
          kind: :file,
          name: "x",
          materialization:
            Materialization.new(:ingestion, :skill_bundle,
              params: %{locator: locator, resource_path: path}
            )
        }

        case Strategy.materialize(record, []) do
          {:ok, _} ->
            flunk("materialized an out-of-bundle path: #{inspect({locator, path})}")

          {:error, _reason} ->
            :ok
        end
      end
    end
  end
end
