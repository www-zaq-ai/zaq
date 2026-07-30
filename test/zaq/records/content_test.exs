defmodule Zaq.Records.ContentTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Record
  alias Zaq.Records.Content

  # A byte sequence that is not valid UTF-8 — a PNG header, which is exactly the case the
  # two image use cases hit.
  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xFE>>
  @text "# Pricing\n\nStandard tier is €40/month.\n"

  defp record(attrs \\ []), do: struct!(%Record{id: "r", kind: :file}, attrs)

  describe "put/3 with as: :auto" do
    test "stores valid UTF-8 as text" do
      {:ok, record} = record() |> Content.put(@text, :auto)

      assert record.content == @text
      assert record.attributes["encoding"] == "utf8"
    end

    test "stores non-UTF-8 as base64" do
      {:ok, record} = record() |> Content.put(@png, :auto)

      assert record.attributes["encoding"] == "base64"
      assert record.content != @png
      assert {:ok, @png} = Base.decode64(record.content)
    end
  end

  describe "put/3 with as: :text" do
    test "stores valid UTF-8 as text" do
      {:ok, record} = record() |> Content.put(@text, :text)

      assert record.content == @text
      assert record.attributes["encoding"] == "utf8"
    end

    # Refusing beats returning base64 a text-only caller cannot use — and for the skills tool
    # specifically, base64 in a context window is cost without meaning.
    test "refuses non-UTF-8 rather than encoding it" do
      assert {:error, :invalid_utf8} = record() |> Content.put(@png, :text)
    end
  end

  describe "put/3 with as: :binary" do
    test "encodes even valid UTF-8" do
      {:ok, record} = record() |> Content.put(@text, :binary)

      assert record.attributes["encoding"] == "base64"
      assert {:ok, @text} = Base.decode64(record.content)
    end
  end

  describe "size" do
    test "reports raw bytes for text" do
      {:ok, record} = record() |> Content.put(@text, :auto)

      assert record.size == byte_size(@text)
    end

    # A cap has to mean the same number on both sides of a node boundary. Base64 inflates by
    # 4/3, so reporting the encoded length would silently move the goalposts.
    test "reports raw bytes for base64, not the encoded length" do
      {:ok, record} = record() |> Content.put(@png, :auto)

      assert record.size == byte_size(@png)
      assert byte_size(record.content) > byte_size(@png)
    end
  end

  describe "decode/1" do
    test "inverts put/3 for text" do
      {:ok, record} = record() |> Content.put(@text, :auto)

      assert {:ok, @text} = Content.decode(record)
    end

    test "inverts put/3 for base64" do
      {:ok, record} = record() |> Content.put(@png, :auto)

      assert {:ok, @png} = Content.decode(record)
    end

    test "inverts put/3 for text forced to binary" do
      {:ok, record} = record() |> Content.put(@text, :binary)

      assert {:ok, @text} = Content.decode(record)
    end

    test "reads an atom-keyed encoding attribute too" do
      assert {:ok, @png} =
               record(content: Base.encode64(@png), attributes: %{encoding: "base64"})
               |> Content.decode()
    end

    test "treats a missing encoding attribute as raw content" do
      assert {:ok, @text} = record(content: @text) |> Content.decode()
    end

    test "refuses a record with no content" do
      assert {:error, :no_content} = record() |> Content.decode()
    end

    test "refuses malformed base64" do
      assert {:error, :invalid_base64} =
               record(content: "not!base64!", attributes: %{"encoding" => "base64"})
               |> Content.decode()
    end

    test "refuses non-binary content" do
      assert {:error, :unsupported_content} = record(content: [%{"a" => 1}]) |> Content.decode()
    end
  end

  describe "round-trip" do
    test "arbitrary bytes survive put/3 then decode/1 exactly" do
      for bytes <- [<<>>, <<0>>, @png, :crypto.strong_rand_bytes(1_024), @text] do
        {:ok, record} = record() |> Content.put(bytes, :auto)

        assert {:ok, ^bytes} = Content.decode(record)
        assert record.size == byte_size(bytes)
      end
    end
  end
end
