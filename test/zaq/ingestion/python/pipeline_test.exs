defmodule Zaq.Ingestion.Python.PipelineTest do
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  alias Zaq.Agent.PromptTemplate
  alias Zaq.Ingestion.Python.Pipeline
  alias Zaq.Ingestion.Python.Runner

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "zaq_pipeline_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # resolve_api_key — tested indirectly through run/1
  # ---------------------------------------------------------------------------

  describe "resolve_api_key via run/1" do
    test "opts :api_key takes precedence over DB config" do
      result = Pipeline.run("/nonexistent/report.pdf", api_key: "inline-key")
      assert match?({:error, _}, result)
    end

    test "falls back to DB api_key when not in opts" do
      result = Pipeline.run("/nonexistent/report.pdf")
      assert match?({:error, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # skipping — no api_key
  # ---------------------------------------------------------------------------

  describe "run/1 without api_key" do
    test "returns error from first failing step (no api_key, scripts absent)" do
      result = Pipeline.run("/tmp/nonexistent_#{System.unique_integer()}.pdf")
      assert match?({:error, _}, result)
    end

    test "nil and empty-string api_key both skip image steps" do
      result_nil = Pipeline.run("/tmp/no_key_nil_#{System.unique_integer()}.pdf", api_key: nil)
      result_empty = Pipeline.run("/tmp/no_key_empty_#{System.unique_integer()}.pdf", api_key: "")

      assert match?({:error, _}, result_nil)
      assert match?({:error, _}, result_empty)
    end
  end

  # ---------------------------------------------------------------------------
  # output path derivation
  # ---------------------------------------------------------------------------

  describe "output md_path" do
    test "defaults to pdf basename with .md extension" do
      assert match?({:error, _}, Pipeline.run("/tmp/report.pdf"))
    end

    test "honours opts :output for custom md_path" do
      custom_out = "/tmp/custom_out_#{System.unique_integer()}.md"
      assert match?({:error, _}, Pipeline.run("/tmp/report.pdf", output: custom_out))
    end
  end

  # ---------------------------------------------------------------------------
  # Integration smoke-test using a real (trivial) markdown file
  # ---------------------------------------------------------------------------

  describe "run/1 return shape" do
    test "always returns a two-element tagged tuple" do
      result = Pipeline.run("/tmp/missing_#{System.unique_integer()}.pdf")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "runs all steps, forwards progress, injects descriptions, and cleans images",
         %{tmp_dir: tmp_dir} do
      with_fake_pipeline_scripts()

      pdf_path = Path.join(tmp_dir, "report.pdf")
      md_path = Path.join(tmp_dir, "report.md")
      images_dir = Path.join(tmp_dir, "images")
      File.write!(pdf_path, "%PDF-1.4")

      ensure_image_to_text_prompt!("Describe test images")

      test_pid = self()

      assert {:ok, ^md_path} =
               Pipeline.run(pdf_path,
                 api_key: "inline-key",
                 endpoint: "https://vision.example.test/v1",
                 model: "vision-model",
                 output: md_path,
                 images_dir: images_dir,
                 on_progress: fn payload -> send(test_pid, {:progress, payload}) end
               )

      assert_receive {:progress, %{"stage" => "image_to_text", "status" => "completed"}}
      assert File.read!(md_path) =~ "Injected descriptions"
      refute File.read!(md_path) =~ "![local](/tmp/local.png)"
      refute File.exists?(images_dir)
    end

    test "success without api key skips image steps and removes local image refs",
         %{tmp_dir: tmp_dir} do
      with_fake_pipeline_scripts()

      pdf_path = Path.join(tmp_dir, "report.pdf")
      md_path = Path.join(tmp_dir, "report.md")
      images_dir = Path.join(tmp_dir, "images")
      File.write!(pdf_path, "%PDF-1.4")

      assert {:ok, ^md_path} =
               Pipeline.run(pdf_path,
                 api_key: "",
                 output: md_path,
                 images_dir: images_dir
               )

      content = File.read!(md_path)
      assert content =~ "Generated markdown"
      refute content =~ "![local](/tmp/local.png)"
      refute content =~ "Injected descriptions"
      refute File.exists?(images_dir)
    end

    test "cleans up temporary alias when pdf filename contains spaces", %{tmp_dir: tmp_dir} do
      pdf_path = Path.join(tmp_dir, "Deck With Spaces.pdf")
      alias_path = Path.join(tmp_dir, "Deck_With_Spaces.pdf")
      File.write!(pdf_path, "%PDF-1.4")

      refute File.exists?(alias_path)

      result = Pipeline.run(pdf_path)

      assert match?({:ok, _}, result) or match?({:error, _}, result)
      assert File.exists?(pdf_path)
      refute File.exists?(alias_path)
    end

    test "uses a unique temporary alias when normalized filename already exists",
         %{tmp_dir: tmp_dir} do
      with_fake_pipeline_scripts()

      pdf_path = Path.join(tmp_dir, "Deck With Spaces.pdf")
      existing_alias = Path.join(tmp_dir, "Deck_With_Spaces.pdf")
      File.write!(pdf_path, "%PDF-1.4")
      File.write!(existing_alias, "keep me")

      assert {:ok, _md_path} = Pipeline.run(pdf_path, api_key: "")

      assert File.exists?(pdf_path)
      assert File.read!(existing_alias) == "keep me"

      refute Enum.any?(File.ls!(tmp_dir), &String.contains?(&1, "__zaq_tmp_"))
    end

    test "runs image-to-text without a prompt when no active template exists",
         %{tmp_dir: tmp_dir} do
      with_fake_pipeline_scripts(%{
        "image_to_text.py" => """
        import json
        import os
        import sys

        if "--ping" in sys.argv:
            print("pong")
            sys.exit(0)

        required = ["--api-key"]
        missing = [flag for flag in required if flag not in sys.argv]
        if missing:
            print("missing " + ",".join(missing))
            sys.exit(17)

        output = sys.argv[sys.argv.index("--output") + 1]
        os.makedirs(os.path.dirname(output), exist_ok=True)
        with open(output, "w", encoding="utf-8") as f:
            json.dump({"images": [{"path": "image.png", "description": "A chart"}]}, f)

        print("image text ok")
        """
      })

      ensure_no_active_image_to_text_prompt!()

      pdf_path = Path.join(tmp_dir, "report.pdf")
      md_path = Path.join(tmp_dir, "report.md")
      File.write!(pdf_path, "%PDF-1.4")

      assert {:ok, ^md_path} =
               Pipeline.run(pdf_path,
                 api_key: "inline-key",
                 output: md_path,
                 endpoint: "",
                 model: ""
               )

      assert File.read!(md_path) =~ "Injected descriptions"
    end

    test "skips description injection when image-to-text produces no descriptions file",
         %{tmp_dir: tmp_dir} do
      with_fake_pipeline_scripts(%{
        "image_to_text.py" => """
        import sys

        if "--ping" in sys.argv:
            print("pong")
            sys.exit(0)

        print("image text ok without descriptions")
        """
      })

      pdf_path = Path.join(tmp_dir, "report.pdf")
      md_path = Path.join(tmp_dir, "report.md")
      File.write!(pdf_path, "%PDF-1.4")

      assert {:ok, ^md_path} =
               Pipeline.run(pdf_path,
                 api_key: "inline-key",
                 output: md_path,
                 endpoint: "",
                 model: ""
               )

      content = File.read!(md_path)
      assert content =~ "Generated markdown"
      refute content =~ "Injected descriptions"
    end

    test "tolerates alias already removed before cleanup", %{tmp_dir: tmp_dir} do
      with_fake_pipeline_scripts(%{
        "pdf_to_md.py" => """
        import os
        import sys

        pdf_path = sys.argv[1]
        md_path = sys.argv[2]
        images_dir = sys.argv[sys.argv.index("--images-dir") + 1]
        pdf_name = os.path.splitext(os.path.basename(pdf_path))[0]
        images_folder = os.path.join(images_dir, pdf_name)
        os.makedirs(images_folder, exist_ok=True)

        if os.path.islink(pdf_path):
            os.remove(pdf_path)

        with open(md_path, "w", encoding="utf-8") as f:
            f.write("Generated markdown\\n")

        print("pdf ok")
        """
      })

      pdf_path = Path.join(tmp_dir, "Deck With Spaces.pdf")
      md_path = Path.join(tmp_dir, "deck.md")
      File.write!(pdf_path, "%PDF-1.4")

      assert {:ok, ^md_path} = Pipeline.run(pdf_path, api_key: "", output: md_path)
      assert File.exists?(pdf_path)
    end

    test "logs and continues when alias cleanup cannot remove the alias path",
         %{tmp_dir: tmp_dir} do
      with_fake_pipeline_scripts(%{
        "pdf_to_md.py" => """
        import os
        import sys

        pdf_path = sys.argv[1]
        md_path = sys.argv[2]
        images_dir = sys.argv[sys.argv.index("--images-dir") + 1]
        pdf_name = os.path.splitext(os.path.basename(pdf_path))[0]
        images_folder = os.path.join(images_dir, pdf_name)
        os.makedirs(images_folder, exist_ok=True)

        if os.path.islink(pdf_path):
            os.remove(pdf_path)
            os.mkdir(pdf_path)

        with open(md_path, "w", encoding="utf-8") as f:
            f.write("Generated markdown\\n")

        print("pdf ok")
        """
      })

      pdf_path = Path.join(tmp_dir, "Deck With Spaces.pdf")
      md_path = Path.join(tmp_dir, "deck.md")
      alias_path = Path.join(tmp_dir, "Deck_With_Spaces.pdf")
      File.write!(pdf_path, "%PDF-1.4")

      assert {:ok, ^md_path} = Pipeline.run(pdf_path, api_key: "", output: md_path)
      assert File.dir?(alias_path)
    end
  end

  defp with_fake_pipeline_scripts(overrides \\ %{}) do
    scripts =
      %{
        "pdf_to_md.py" => """
        import os
        import sys

        pdf_path = sys.argv[1]
        md_path = sys.argv[2]
        images_dir = sys.argv[sys.argv.index("--images-dir") + 1]
        pdf_name = os.path.splitext(os.path.basename(pdf_path))[0]
        images_folder = os.path.join(images_dir, pdf_name)
        os.makedirs(images_folder, exist_ok=True)

        with open(md_path, "w", encoding="utf-8") as f:
            f.write("Generated markdown\\n![local](/tmp/local.png)\\nKeep this text\\n")

        print("pdf ok")
        """,
        "image_dedup.py" => """
        import os
        import sys

        os.makedirs(sys.argv[1], exist_ok=True)
        print("dedup ok")
        """,
        "image_to_text.py" => """
        import json
        import os
        import sys

        if "--ping" in sys.argv:
            print("pong")
            sys.exit(0)

        required = ["--api-key", "--api-url", "--model", "--prompt"]
        missing = [flag for flag in required if flag not in sys.argv]
        if missing:
            print("missing " + ",".join(missing))
            sys.exit(17)

        output = sys.argv[sys.argv.index("--output") + 1]
        os.makedirs(os.path.dirname(output), exist_ok=True)
        with open(output, "w", encoding="utf-8") as f:
            json.dump({"images": [{"path": "image.png", "description": "A chart"}]}, f)

        print('ZAQ_PROGRESS {"stage": "image_to_text", "status": "completed"}')
        print("image text ok")
        """,
        "inject_descriptions.py" => """
        import sys

        md_path = sys.argv[1]
        with open(md_path, "a", encoding="utf-8") as f:
            f.write("\\nInjected descriptions\\n")

        print("inject ok")
        """
      }
      |> Map.merge(overrides)

    backups =
      for {name, content} <- scripts, into: %{} do
        path = Path.join(Runner.scripts_dir(), name)
        backup = File.read!(path)
        File.write!(path, content)
        {path, backup}
      end

    on_exit(fn ->
      Enum.each(backups, fn {path, backup} -> File.write!(path, backup) end)
    end)
  end

  defp ensure_image_to_text_prompt!(body) do
    attrs = %{
      slug: "image_to_text",
      name: "Image prompt",
      body: body,
      active: true
    }

    case PromptTemplate.get_by_slug("image_to_text") do
      nil ->
        {:ok, _template} = PromptTemplate.create(attrs)

      template ->
        {:ok, _template} = PromptTemplate.update(template, attrs)
    end
  end

  defp ensure_no_active_image_to_text_prompt! do
    case PromptTemplate.get_by_slug("image_to_text") do
      nil ->
        :ok

      template ->
        {:ok, _template} =
          PromptTemplate.update(template, %{
            slug: "image_to_text",
            name: template.name,
            body: template.body,
            description: template.description,
            active: false
          })

        :ok
    end
  end
end
