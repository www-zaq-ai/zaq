defmodule ZaqWeb.Helpers.UploadFlashTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Helpers.UploadFlash

  # Minimal socket — put_flash/3 only touches the flash assign.
  defp socket, do: %Phoenix.LiveView.Socket{assigns: %{flash: %{}, __changed__: %{}}}

  defp flash(socket, key), do: Map.get(socket.assigns.flash, to_string(key))

  describe "put_result/4 defaults (ingestion wording)" do
    test "reports a fully successful batch" do
      result = UploadFlash.put_result(socket(), [{:ok, "a"}, {:ok, "b"}], [])

      assert flash(result, :info) == "2 file(s) uploaded."
    end

    test "reports a partial batch as info, naming both counts" do
      result = UploadFlash.put_result(socket(), [{:ok, "a"}], [{:error, :eacces}])

      assert flash(result, :info) == "1 file(s) uploaded. 1 failed."
    end

    test "reports a fully failed batch as an error" do
      result = UploadFlash.put_result(socket(), [], [{:error, :eacces}])

      assert flash(result, :error) == "Upload failed: :eacces"
    end

    test "deduplicates repeated failure reasons" do
      result =
        UploadFlash.put_result(socket(), [], [
          {:error, :eacces},
          {:error, :eacces},
          {:error, :enospc}
        ])

      assert flash(result, :error) == "Upload failed: :eacces, :enospc"
    end

    test "sets no flash when nothing was consumed" do
      result = UploadFlash.put_result(socket(), [], [])

      assert result.assigns.flash == %{}
    end
  end

  describe "put_result/4 with domain wording" do
    test "uses the caller's noun and past tense" do
      result =
        UploadFlash.put_result(socket(), [{:ok, "a"}], [], noun: "resource", past_tense: "added")

      assert flash(result, :info) == "1 resource(s) added."
    end

    test "applies the wording to the partial case too" do
      result =
        UploadFlash.put_result(socket(), [{:ok, "a"}], [{:error, :eacces}],
          noun: "resource",
          past_tense: "added"
        )

      assert flash(result, :info) == "1 resource(s) added. 1 failed."
    end

    test "the failure message stays domain-neutral" do
      result =
        UploadFlash.put_result(socket(), [], [{:error, :eacces}],
          noun: "resource",
          past_tense: "added"
        )

      assert flash(result, :error) == "Upload failed: :eacces"
    end
  end
end
