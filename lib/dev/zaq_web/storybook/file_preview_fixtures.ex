defmodule ZaqWeb.Storybook.FilePreviewFixtures do
  @moduledoc false

  alias ZaqWeb.Helpers.Markdown

  @sample_mtime ~U[2024-03-15 09:22:07Z]

  # 1×1 transparent PNG (offline-safe for <img src> and Raw link).
  @png_data_uri "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  # Minimal valid PDF (single "Test" page) for <iframe src>.
  @pdf_data_uri "data:application/pdf;base64,JVBERi0xLjQKJeLjz9MKMSAwIG9iago8PAovVHlwZSAvQ2F0YWxvZwovUGFnZXMgMiAwIFIKPj4KZW5kb2JqCjIgMCBvYmoKPDwKL1R5cGUgL1BhZ2VzCi9LaWRzIFszIDAgUl0KL0NvdW50IDEKL01lZGlhQm94IFswIDAgNjEyIDc5Ml0KPj4KZW5kb2JqCjMgMCBvYmoKPDwKL1R5cGUgL1BhZ2UKL1BhcmVudCAyIDAgUgovUmVzb3VyY2VzIDw8Ci9Gb250IDw8Ci9GMSA0IDAgUgo+Pgo+PgovQ29udGVudHMgNSAwIFIKPj4KZW5kb2JqCjQgMCBvYmoKPDwKL1R5cGUgL0ZvbnQKL1N1YnR5cGUgL1R5cGUxCi9CYXNlRm9udCAvSGVsdmV0aWNhCj4+CmVuZG9iago1IDAgb2JqCjw8Ci9MZW5ndGggNDQKPj4Kc3RyZWFtCkJUL0YxIDEyIFRmIDEwMCA3MDAgVGQgKFRlc3QpIFRqIEVUCmVuZHN0cmVhbQplbmRvYmoKdHJhaWxlcgo8PAovUm9vdCAxIDAgUgovU2l6ZSA2Cj4+CnN0YXJ0eHJlZgoxNzIKJSVFT0Y="

  @doc "Map shape matches `ZaqWeb.Live.BO.AI.FilePreviewData.load/2` success branch."
  def markdown do
    md = """
    # Onboarding

    Welcome to **ZAQ**. This mirrors real ingestion markdown preview.

    - Item one
    - Item two
    """

    %{
      relative_path: "docs/handbook/onboarding.md",
      filename: "onboarding.md",
      ext: ".md",
      kind: :markdown,
      content: md,
      rendered_html: Markdown.render(md),
      file_size: 512,
      modified_at: @sample_mtime,
      raw_url: "/bo/files/docs/handbook/onboarding.md"
    }
  end

  def text do
    content = """
    # Onboarding Guide

    Welcome to ZAQ. This guide covers the first steps for new team members.

    ## Step 1: Account setup

    Your IT team will provide your initial credentials.
    """

    %{
      relative_path: "docs/readme.txt",
      filename: "readme.txt",
      ext: ".txt",
      kind: :text,
      content: content,
      rendered_html: nil,
      file_size: 1024,
      modified_at: @sample_mtime,
      raw_url: "/bo/files/docs/readme.txt"
    }
  end

  def image do
    %{
      relative_path: "assets/logo.png",
      filename: "logo.png",
      ext: ".png",
      kind: :image,
      content: nil,
      rendered_html: nil,
      file_size: 128,
      modified_at: @sample_mtime,
      raw_url: @png_data_uri
    }
  end

  def pdf do
    %{
      relative_path: "reports/quarterly.pdf",
      filename: "quarterly.pdf",
      ext: ".pdf",
      kind: :pdf,
      content: nil,
      rendered_html: nil,
      file_size: 24_576,
      modified_at: @sample_mtime,
      raw_url: @pdf_data_uri
    }
  end

  def binary do
    %{
      relative_path: "archive/data.xlsx",
      filename: "data.xlsx",
      ext: ".xlsx",
      kind: :binary,
      content: nil,
      rendered_html: nil,
      file_size: 4096,
      modified_at: @sample_mtime,
      raw_url: "data:application/octet-stream;base64,WkFR"
    }
  end

  @doc "Matches `FilePreviewData.load/2` not-found branch (header still has filename/ext/path)."
  def not_found do
    relative = "documents/missing-file.pdf"

    %{
      relative_path: relative,
      filename: "missing-file.pdf",
      ext: ".pdf",
      kind: :not_found,
      content: nil,
      rendered_html: nil,
      file_size: nil,
      modified_at: nil,
      raw_url: nil
    }
  end

  def meta_only_preview do
    %{file_size: 24_576, modified_at: @sample_mtime}
  end
end
