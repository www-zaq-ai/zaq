defmodule Zaq.Ingestion.ArtifactTypeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Ingestion.ArtifactType

  @mappings [
    {"application/vnd.openxmlformats-officedocument.wordprocessingml.document", ".docx"},
    {"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ".xlsx"},
    {"application/vnd.openxmlformats-officedocument.presentationml.presentation", ".pptx"},
    {"application/json-patch+json", ".json-patch"},
    {"application/ld+json", ".jsonld"},
    {"application/pdf", ".pdf"},
    {"image/jpeg", ".jpg"},
    {"application/octet-stream", ".bin"}
  ]

  test "maps supported artifact MIME types to canonical extensions" do
    for {mime, extension} <- @mappings do
      assert ArtifactType.canonical_extension(mime) == extension
      assert ArtifactType.compatible_extension?(mime, extension)
    end
  end

  test "accepts compatible aliases and normalizes case and MIME parameters" do
    assert ArtifactType.canonical_extension(" Application/PDF ; charset=binary ") == ".pdf"
    assert ArtifactType.compatible_extension?(" IMAGE/JPEG; x=y", ".JPEG")
    refute ArtifactType.compatible_extension?("application/pdf", ".docx")
  end

  test "preserves hyphenated extensions registered by MIME" do
    assert ArtifactType.canonical_extension("application/json-patch+json") == ".json-patch"
    assert ArtifactType.compatible_extension?("application/json-patch+json", ".JSON-PATCH")
    assert ArtifactType.filename_extension("Report.JSON-PATCH") == ".json-patch"
  end

  test "missing or unmapped MIME and unsafe extensions have no mapping" do
    for mime <- [nil, "", "  ", "application/x-zaq-unknown"] do
      assert ArtifactType.canonical_extension(mime) == nil
      refute ArtifactType.compatible_extension?(mime, ".pdf")
    end

    for extension <- [nil, "", ".", "pdf", "../pdf", ".pdf/evil", ".pdf\\evil", ".pdf\n", ".pdf "] do
      refute ArtifactType.compatible_extension?("application/pdf", extension)
    end
  end

  test "rejects structured-suffix fallbacks for unrecognized specific MIME types" do
    for mime <- [
          "application/vnd.zaq-unknown+zip",
          "application/vnd.zaq-unknown+json",
          "application/vnd.zaq-unknown+xml"
        ] do
      assert ArtifactType.canonical_extension(mime) == nil
      refute ArtifactType.compatible_extension?(mime, ".zip")
      refute ArtifactType.compatible_extension?(mime, ".json")
      refute ArtifactType.compatible_extension?(mime, ".xml")
    end
  end

  test "owns filename-extension safety and nonspecific MIME classification" do
    assert ArtifactType.filename_extension("Report.DOCX") == ".docx"
    assert ArtifactType.filename_extension("archive.tar.gz") == ".gz"

    for filename <- [
          nil,
          "",
          "Report",
          "Report.",
          "Report.bad suffix",
          "Report.pdf ",
          "Report.pdf/evil",
          "../Report.pdf",
          "Report.pdf/evil.pdf",
          "Report\\evil.pdf",
          "Report.pdf\\evil"
        ] do
      assert ArtifactType.filename_extension(filename) == nil
    end

    for mime <- [nil, "", "  ", " APPLICATION/OCTET-STREAM; x=y"] do
      assert ArtifactType.nonspecific_mime?(mime)
    end

    for mime <- ["application/pdf", "application/vnd.zaq-unknown+zip", :not_a_mime] do
      refute ArtifactType.nonspecific_mime?(mime)
    end
  end

  property "canonical extensions come from explicitly registered MIME mappings" do
    check all(
            mime <-
              one_of([
                member_of(Enum.map(@mappings, &elem(&1, 0))),
                string(:alphanumeric, max_length: 40)
              ]),
            max_runs: 50
          ) do
      if extension = ArtifactType.canonical_extension(mime) do
        assert String.trim_leading(extension, ".") in Map.fetch!(MIME.known_types(), mime)
      end
    end
  end

  property "unsafe filename suffixes never pass external extension validation" do
    check all(
            suffix <- string(:alphanumeric, min_length: 1, max_length: 20),
            unsafe <- member_of(["/", "\\", " ", "\n"]),
            max_runs: 50
          ) do
      extension = "." <> suffix <> unsafe <> "evil"
      refute ArtifactType.compatible_extension?("application/pdf", extension)
      assert ArtifactType.filename_extension("Report" <> extension) == nil
    end
  end
end
