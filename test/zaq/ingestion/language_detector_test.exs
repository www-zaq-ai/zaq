defmodule Zaq.Ingestion.LanguageDetectorTest do
  use ExUnit.Case, async: false

  alias Zaq.Ingestion.LanguageDetector

  defmodule LinguaNoMatchStub do
    def detect(_text, _opts), do: {:ok, :no_match}
  end

  defmodule LinguaAtomStub do
    def detect(_text, _opts), do: {:ok, :english}
  end

  defmodule LinguaUnknownAtomStub do
    def detect(_text, _opts), do: {:ok, :japanese}
  end

  defmodule LinguaErrorStub do
    def detect(_text, _opts), do: {:error, "nif crashed"}
  end

  defp with_lingua_stub(module, fun) do
    original = Application.get_env(:zaq, :lingua_module)
    Application.put_env(:zaq, :lingua_module, module)

    try do
      fun.()
    after
      if is_nil(original) do
        Application.delete_env(:zaq, :lingua_module)
      else
        Application.put_env(:zaq, :lingua_module, original)
      end
    end
  end

  describe "detect/1" do
    test "returns 'english' for clear English text with ≥ 20 tokens" do
      text = String.duplicate("the quick brown fox jumps over the lazy dog ", 5)
      assert LanguageDetector.detect(text) == "english"
    end

    test "returns 'french' for clear French text with ≥ 20 tokens" do
      text =
        String.duplicate(
          "le renard brun rapide saute par dessus le chien paresseux dans le jardin ",
          4
        )

      assert LanguageDetector.detect(text) == "french"
    end

    test "returns 'spanish' for clear Spanish text with ≥ 20 tokens" do
      text =
        String.duplicate(
          "el zorro marrón rápido salta sobre el perro perezoso en el jardín ",
          4
        )

      assert LanguageDetector.detect(text) == "spanish"
    end

    test "returns 'arabic' for clear Arabic text with ≥ 20 tokens" do
      text =
        String.duplicate(
          "الثعلب البني السريع يقفز فوق الكلب الكسول في الحديقة الجميلة ",
          4
        )

      assert LanguageDetector.detect(text) == "arabic"
    end

    test "returns 'simple' for chunks with fewer than 20 tokens" do
      assert LanguageDetector.detect("short text") == "simple"
      assert LanguageDetector.detect("hello world") == "simple"
    end

    test "returns 'simple' when confidence is below 0.8 threshold" do
      # Repeated single character words: very low confidence
      assert LanguageDetector.detect("a b c d e f g h i j k l m n o p q r s t u v w") ==
               "simple"
    end

    test "different chunks from a mixed-language document return different languages" do
      english_text = String.duplicate("the quick brown fox jumps over the lazy dog ", 5)

      french_text =
        String.duplicate(
          "le renard brun rapide saute par dessus le chien paresseux dans le jardin ",
          4
        )

      english_lang = LanguageDetector.detect(english_text)
      french_lang = LanguageDetector.detect(french_text)

      refute english_lang == french_lang
    end

    test "returns a string in all cases (never raises)" do
      for text <- ["", "   ", "\n\n", "123 456 789"] do
        result = LanguageDetector.detect(text)
        assert is_binary(result)
      end
    end
  end

  describe "detect_query/1" do
    test "returns 'simple' for queries with fewer than 3 tokens" do
      assert LanguageDetector.detect_query("hello") == "simple"
      assert LanguageDetector.detect_query("two words") == "simple"
      assert LanguageDetector.detect_query("") == "simple"
    end

    test "calls detect_with_confidence for queries with 3+ tokens" do
      with_lingua_stub(LinguaAtomStub, fn ->
        assert LanguageDetector.detect_query("what is the weather") == "english"
      end)
    end

    test "returns 'simple' for low-confidence query text" do
      assert LanguageDetector.detect_query("a b c d e") == "simple"
    end
  end

  describe "detect_with_confidence/1 edge cases" do
    test "returns 'simple' when Lingua returns :no_match" do
      with_lingua_stub(LinguaNoMatchStub, fn ->
        text = String.duplicate("word ", 25)
        assert LanguageDetector.detect(text) == "simple"
      end)
    end

    test "returns mapped language when Lingua returns atom for known language" do
      with_lingua_stub(LinguaAtomStub, fn ->
        text = String.duplicate("word ", 25)
        assert LanguageDetector.detect(text) == "english"
      end)
    end

    test "returns language string when Lingua returns atom for any language" do
      with_lingua_stub(LinguaUnknownAtomStub, fn ->
        text = String.duplicate("word ", 25)
        assert LanguageDetector.detect(text) == "japanese"
      end)
    end

    test "returns 'simple' when Lingua returns unexpected value" do
      with_lingua_stub(LinguaErrorStub, fn ->
        text = String.duplicate("word ", 25)
        assert LanguageDetector.detect(text) == "simple"
      end)
    end
  end
end
