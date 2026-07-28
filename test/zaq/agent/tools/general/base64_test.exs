defmodule Zaq.Agent.Tools.General.Base64Test do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.General.DecodeBase64
  alias Zaq.Agent.Tools.General.EncodeBase64
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Engine.Workflows.Action

  defp encode(params) do
    with {:ok, validated} <- EncodeBase64.validate_params(params) do
      EncodeBase64.run(validated, %{})
    end
  end

  defp decode(params) do
    with {:ok, validated} <- DecodeBase64.validate_params(params) do
      DecodeBase64.run(validated, %{})
    end
  end

  test "both satisfy the workflow action contract" do
    assert :ok = Action.validate(EncodeBase64)
    assert :ok = Action.validate(DecodeBase64)
  end

  test "both are registered in the tool registry" do
    assert {:ok, [EncodeBase64]} = Registry.resolve_modules(["general.encode_base64"])
    assert {:ok, [DecodeBase64]} = Registry.resolve_modules(["general.decode_base64"])
  end

  describe "encoding" do
    test "encodes text with standard padding by default" do
      assert {:ok, %{encoded: "aGVsbG8="}} = encode(%{data: "hello"})
    end

    test "encodes without padding when asked" do
      assert {:ok, %{encoded: "aGVsbG8"}} = encode(%{data: "hello", padding: false})
    end

    test "uses the url-safe alphabet when asked" do
      # This input encodes to "a+/w" in standard, "a-_w" in url-safe.
      binary = <<107, 239, 240>>

      assert {:ok, %{encoded: "a+/w"}} = encode(%{data: binary})
      assert {:ok, %{encoded: "a-_w"}} = encode(%{data: binary, variant: "url_safe"})
    end

    test "encodes multi-byte text and an empty string" do
      assert {:ok, %{encoded: encoded}} = encode(%{data: "héllo → wörld"})
      assert {:ok, %{decoded: "héllo → wörld"}} = decode(%{data: encoded})

      assert {:ok, %{encoded: ""}} = encode(%{data: ""})
    end

    test "requires data and rejects an unknown variant" do
      assert {:error, _} = EncodeBase64.validate_params(%{})
      assert {:error, _} = EncodeBase64.validate_params(%{data: "x", variant: "base32"})
    end
  end

  describe "decoding" do
    test "decodes a padded standard string" do
      assert {:ok, %{decoded: "hello"}} = decode(%{data: "aGVsbG8="})
    end

    test "decodes without padding" do
      assert {:ok, %{decoded: "hello"}} = decode(%{data: "aGVsbG8"})
    end

    test "auto-detects the url-safe alphabet" do
      assert {:ok, %{decoded: "~ÿ~"}} = decode(%{data: "fsO_fg"})
      assert {:ok, %{decoded: "subjects?_d=1"}} = decode(%{data: "c3ViamVjdHM_X2Q9MQ"})
    end

    test "strips whitespace and line breaks" do
      assert {:ok, %{decoded: "hello"}} = decode(%{data: "aGVs\nbG8="})
      assert {:ok, %{decoded: "hello"}} = decode(%{data: "  aGVsbG8=  "})
      assert {:ok, %{decoded: "hello"}} = decode(%{data: "aGVs bG8="})
    end

    test "honours an explicit variant and refuses the wrong alphabet" do
      # "subjects?_d=1" encodes to ...TM/X2Q9MQ in standard, ...TM_X2Q9MQ in url-safe,
      # so each string is decodable under exactly one alphabet.
      url_safe = "c3ViamVjdHM_X2Q9MQ"
      standard = "c3ViamVjdHM/X2Q9MQ"

      assert {:ok, %{decoded: "subjects?_d=1"}} = decode(%{data: url_safe, variant: "url_safe"})
      assert {:ok, %{decoded: "subjects?_d=1"}} = decode(%{data: standard, variant: "standard"})

      assert {:error, message} = decode(%{data: url_safe, variant: "standard"})
      assert message =~ "standard alphabet"

      assert {:error, message} = decode(%{data: standard, variant: "url_safe"})
      assert message =~ "url_safe alphabet"
    end

    test "refuses a payload that decodes to binary rather than text" do
      binary_b64 = Base.encode64(<<0xFF, 0xFE, 0x00, 0x01>>)

      assert {:error, message} = decode(%{data: binary_b64})
      assert message =~ "4 bytes of binary data"
      assert message =~ "returns text only"
    end

    test "rejects input that is not Base64 at all" do
      assert {:error, message} = decode(%{data: "not base64!!"})
      assert message =~ "standard or URL-safe"

      assert {:error, _} = decode(%{data: "aGVsbG8======"})
    end

    test "decodes an empty string" do
      assert {:ok, %{decoded: ""}} = decode(%{data: ""})
    end

    test "requires data and rejects an unknown variant" do
      assert {:error, _} = DecodeBase64.validate_params(%{})
      assert {:error, _} = DecodeBase64.validate_params(%{data: "x", variant: "base32"})
    end
  end

  describe "round trip" do
    test "every variant and padding combination round-trips" do
      for text <- ["hello", "héllo → wörld", "", "a", "ab", "abc", String.duplicate("x", 1000)],
          variant <- ["standard", "url_safe"],
          padding <- [true, false] do
        assert {:ok, %{encoded: encoded}} =
                 encode(%{data: text, variant: variant, padding: padding})

        assert {:ok, %{decoded: ^text}} = decode(%{data: encoded, variant: variant}),
               "round trip failed for #{inspect(text)} (#{variant}, padding: #{padding})"

        assert {:ok, %{decoded: ^text}} = decode(%{data: encoded})
      end
    end
  end
end
