defmodule Zaq.Ingestion.Actions.UploadFileTest do
  use Zaq.DataCase, async: true

  alias Zaq.Ingestion.Actions.UploadFile

  defp tmp_file(content \\ "# Hello") do
    path =
      Path.join(System.tmp_dir!(), "upload_file_test_#{System.unique_integer([:positive])}.md")

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "run/2" do
    test "returns {:ok, %{file_path: resolved}} when file exists" do
      path = tmp_file()

      assert {:ok, %{file_path: ^path}} =
               UploadFile.run(%{file_path: path, volume_name: nil}, %{})
    end

    test "returns {:error, _} when file does not exist" do
      path = "/nonexistent/path/to/file.md"
      assert {:error, msg} = UploadFile.run(%{file_path: path, volume_name: nil}, %{})
      assert msg =~ "File not found"
    end

    test "resolves path via volume_name when configured" do
      vol_dir = Path.join(System.tmp_dir!(), "upload_vol_#{System.unique_integer([:positive])}")
      File.mkdir_p!(vol_dir)
      File.write!(Path.join(vol_dir, "report.md"), "# Report")
      on_exit(fn -> File.rm_rf(vol_dir) end)

      original = Application.get_env(:zaq, Zaq.Ingestion)

      on_exit(fn ->
        if is_nil(original),
          do: Application.delete_env(:zaq, Zaq.Ingestion),
          else: Application.put_env(:zaq, Zaq.Ingestion, original)
      end)

      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"vol1" => vol_dir})

      expected = Path.join(vol_dir, "report.md")

      assert {:ok, %{file_path: ^expected}} =
               UploadFile.run(%{file_path: "report.md", volume_name: "vol1"}, %{})
    end

    test "falls back to raw path when volume resolution fails" do
      path = "/some/absolute/file.md"
      # File does not exist → falls back → error
      assert {:error, msg} = UploadFile.run(%{file_path: path, volume_name: nil}, %{})
      assert msg =~ "File not found"
    end
  end
end
