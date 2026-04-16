defmodule Zaq.System.IngestionConfigTest do
  use ExUnit.Case, async: true

  alias Zaq.System.IngestionConfig

  @valid_attrs %{
    base_path: "/zaq/volumes/documents",
    max_context_window: 5_000,
    distance_threshold: 1.2,
    hybrid_search_limit: 20,
    chunk_min_tokens: 400,
    chunk_max_tokens: 900
  }

  # ---------------------------------------------------------------------------
  # embedded_schema — struct creation (line 9)
  # ---------------------------------------------------------------------------

  describe "embedded_schema" do
    test "has the expected default values" do
      config = %IngestionConfig{}
      assert config.max_context_window == 5_000
      assert config.distance_threshold == 1.2
      assert config.hybrid_search_limit == 20
      assert config.chunk_min_tokens == 400
      assert config.chunk_max_tokens == 900
      assert config.base_path == "/zaq/volumes/documents"
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — valid attrs
  # ---------------------------------------------------------------------------

  describe "changeset/2 valid" do
    test "returns a valid changeset with all fields" do
      changeset = IngestionConfig.changeset(%IngestionConfig{}, @valid_attrs)
      assert changeset.valid?
    end

    test "accepts custom values" do
      attrs = %{
        @valid_attrs
        | max_context_window: 8_000,
          chunk_min_tokens: 100,
          chunk_max_tokens: 500
      }

      assert IngestionConfig.changeset(%IngestionConfig{}, attrs).valid?
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — required validation
  # ---------------------------------------------------------------------------

  describe "changeset/2 required" do
    test "is invalid without base_path" do
      changeset =
        IngestionConfig.changeset(
          %IngestionConfig{base_path: nil},
          Map.delete(@valid_attrs, :base_path)
        )

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :base_path)
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — numeric validations
  # ---------------------------------------------------------------------------

  describe "changeset/2 numeric" do
    test "rejects max_context_window of 0" do
      changeset =
        IngestionConfig.changeset(%IngestionConfig{}, %{@valid_attrs | max_context_window: 0})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :max_context_window)
    end

    test "rejects distance_threshold of 0.0" do
      changeset =
        IngestionConfig.changeset(%IngestionConfig{}, %{@valid_attrs | distance_threshold: 0.0})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :distance_threshold)
    end

    test "rejects hybrid_search_limit of 0" do
      changeset =
        IngestionConfig.changeset(%IngestionConfig{}, %{@valid_attrs | hybrid_search_limit: 0})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :hybrid_search_limit)
    end

    test "rejects chunk_min_tokens of 0" do
      changeset =
        IngestionConfig.changeset(%IngestionConfig{}, %{@valid_attrs | chunk_min_tokens: 0})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :chunk_min_tokens)
    end

    test "rejects chunk_max_tokens of 0" do
      changeset =
        IngestionConfig.changeset(%IngestionConfig{}, %{@valid_attrs | chunk_max_tokens: 0})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :chunk_max_tokens)
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — validate_chunk_order (line 34)
  # ---------------------------------------------------------------------------

  describe "changeset/2 chunk order" do
    test "is invalid when chunk_min_tokens equals chunk_max_tokens" do
      attrs = %{@valid_attrs | chunk_min_tokens: 500, chunk_max_tokens: 500}
      changeset = IngestionConfig.changeset(%IngestionConfig{}, attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :chunk_max_tokens)
    end

    test "is invalid when chunk_min_tokens exceeds chunk_max_tokens" do
      attrs = %{@valid_attrs | chunk_min_tokens: 900, chunk_max_tokens: 400}
      changeset = IngestionConfig.changeset(%IngestionConfig{}, attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :chunk_max_tokens)
    end

    test "is valid when chunk_max_tokens is greater than chunk_min_tokens" do
      attrs = %{@valid_attrs | chunk_min_tokens: 100, chunk_max_tokens: 200}
      assert IngestionConfig.changeset(%IngestionConfig{}, attrs).valid?
    end
  end
end
