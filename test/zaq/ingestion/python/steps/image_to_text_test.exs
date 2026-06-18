defmodule Zaq.Ingestion.Python.Steps.ImageToTextTest do
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  alias Zaq.Ingestion.Python.Runner
  alias Zaq.Ingestion.Python.Steps.ImageToText
  alias Zaq.SystemConfigFixtures

  # ---------------------------------------------------------------------------
  # run/3 — delegates to Runner.run/2 with flag-style args
  # ---------------------------------------------------------------------------

  describe "run/3" do
    test "passes folder, output, options, and progress callback to the script", %{
      tmp_dir: tmp_dir
    } do
      with_fake_image_to_text_script()

      output = Path.join(tmp_dir, "descriptions.json")
      test_pid = self()

      assert {:ok, returned_output} =
               ImageToText.run("/tmp/images", output,
                 api_key: "test-api-key",
                 endpoint: "https://vision.example.test/v1",
                 model: "vision-model",
                 prompt: "Describe the image",
                 on_progress: fn payload -> send(test_pid, {:progress, payload}) end
               )

      assert_receive {:progress, %{"stage" => "image_to_text", "status" => "completed"}}
      assert returned_output =~ "ARGS:"
      assert returned_output =~ "--folder /tmp/images"
      assert returned_output =~ "--output #{output}"
      assert returned_output =~ "--api-key test-api-key"
      assert returned_output =~ "--api-url https://vision.example.test/v1"
      assert returned_output =~ "--model vision-model"
      assert returned_output =~ "--prompt Describe the image"
    end

    test "returns {:error, _} when script is absent (no real Python env)" do
      result = ImageToText.run("/tmp/images", "/tmp/descriptions.json", "test-api-key")
      assert match?({:error, _}, result)
    end

    test "returns a two-element tagged tuple" do
      result =
        ImageToText.run(
          "/tmp/nonexistent_images",
          "/tmp/nonexistent_descriptions.json",
          "some-key"
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "does not raise for any string arguments" do
      result = ImageToText.run("", "", "")
      assert elem(result, 0) in [:ok, :error]
    end
  end

  describe "run_single/3" do
    test "passes single image, output, and options to the script", %{tmp_dir: tmp_dir} do
      with_fake_image_to_text_script()

      output = Path.join(tmp_dir, "single.json")

      assert {:ok, returned_output} =
               ImageToText.run_single("/tmp/image.png", output,
                 api_key: "test-api-key",
                 endpoint: "https://vision.example.test/v1",
                 model: "vision-model",
                 prompt: "Describe one"
               )

      assert returned_output =~ "ARGS:/tmp/image.png"
      assert returned_output =~ "--output #{output}"
      assert returned_output =~ "--api-key test-api-key"
      assert returned_output =~ "--api-url https://vision.example.test/v1"
      assert returned_output =~ "--model vision-model"
      assert returned_output =~ "--prompt Describe one"
    end

    test "returns {:error, _} when script is absent (no real Python env)" do
      result = ImageToText.run_single("/tmp/image.png", "/tmp/descriptions.json", "test-api-key")
      assert match?({:error, _}, result)
    end

    test "returns a two-element tagged tuple" do
      result = ImageToText.run_single("/tmp/nonexistent.jpg", "/tmp/output.json", "some-key")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "ping/0" do
    test "returns :ok when configured script ping succeeds" do
      with_fake_image_to_text_script()

      SystemConfigFixtures.seed_image_to_text_config(%{
        api_key: "ping-key",
        endpoint: "https://ping.test/v1"
      })

      assert :ok = ImageToText.ping()
    end

    test "returns script output when configured script ping fails" do
      with_fake_image_to_text_script(exit_on_ping: 23)

      SystemConfigFixtures.seed_image_to_text_config(%{
        api_key: "ping-key",
        endpoint: "https://ping.test/v1"
      })

      assert {:error, output} = ImageToText.ping()
      assert output =~ "ARGS:--ping"
    end
  end

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "zaq_image_to_text_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  defp with_fake_image_to_text_script(opts \\ []) do
    path = Path.join(Runner.scripts_dir(), "image_to_text.py")
    backup = File.read!(path)
    exit_on_ping = Keyword.get(opts, :exit_on_ping, 0)

    File.write!(path, """
    import sys

    print("ARGS:" + " ".join(sys.argv[1:]))
    print('ZAQ_PROGRESS {"stage": "image_to_text", "status": "completed"}')
    if "--ping" in sys.argv:
        sys.exit(#{exit_on_ping})
    sys.exit(0)
    """)

    on_exit(fn -> File.write!(path, backup) end)
  end
end
