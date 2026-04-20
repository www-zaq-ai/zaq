defmodule Zaq.Ingestion.LanguageDetectorTest do
  use ExUnit.Case, async: true

  alias Zaq.Ingestion.LanguageDetector

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
end
