defmodule Zaq.Materialization.SinkTest do
  use ExUnit.Case, async: true

  alias Zaq.Materialization.Sink

  setup do
    dir = Path.join(System.tmp_dir!(), "sink_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "quota" do
    test "accepts exactly max_bytes and rejects one byte more", %{dir: dir} do
      {:ok, ok_sink} = Sink.open(mode: :file, max_bytes: 10, dir: dir)
      assert :ok = Sink.write(ok_sink, "12345")
      assert :ok = Sink.write(ok_sink, "67890")
      assert {:ok, %{path: path, size: 10}} = Sink.finish(ok_sink)
      assert File.read!(path) == "1234567890"

      {:ok, over} = Sink.open(mode: :file, max_bytes: 10, dir: dir)
      assert :ok = Sink.write(over, "12345")
      assert {:error, {:materialization_limit, 10}} = Sink.write(over, "678901")
      # a failed sink refuses further writes and reports the failure
      assert {:error, {:materialization_limit, 10}} = Sink.write(over, "")
      assert %{failure: {:materialization_limit, 10}} = Sink.stats(over)
      assert {:error, {:materialization_limit, 10}} = Sink.finish(over)
    end

    test "overflow removes the partial file and keeps finished files", %{dir: dir} do
      {:ok, finished} = Sink.open(mode: :file, max_bytes: 4, dir: dir)
      :ok = Sink.write(finished, "abcd")
      {:ok, %{path: kept}} = Sink.finish(finished)

      {:ok, over} = Sink.open(mode: :file, max_bytes: 4, dir: dir)
      :ok = Sink.write(over, "ab")
      assert [_kept, _partial] = Enum.sort(File.ls!(dir))
      assert {:error, _} = Sink.write(over, "cdef")

      assert File.ls!(dir) == [Path.basename(kept)]
    end

    test "a declared size over the quota is rejected before any byte is written", %{dir: dir} do
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 10, dir: dir)
      assert {:error, {:materialization_limit, 10}} = Sink.start(sink, 11)
      refute File.exists?(dir)
    end

    test "a wrong declared size is not trusted for accounting", %{dir: dir} do
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 10, dir: dir)
      assert :ok = Sink.start(sink, 1)
      assert :ok = Sink.write(sink, "0123456789")
      assert {:error, {:materialization_limit, 10}} = Sink.write(sink, "x")
    end

    test "a failed sink keeps its first failure across producer operations" do
      {:ok, sink} = Sink.open(mode: :memory, max_bytes: 3)
      assert {:error, {:materialization_limit, 3}} = Sink.write(sink, "four")
      assert :ok = Sink.fail(sink, :later_error)
      assert {:error, {:materialization_limit, 3}} = Sink.start(sink)
      assert {:error, {:materialization_limit, 3}} = Sink.mark_text(sink)
      assert {:error, {:materialization_limit, 3}} = Sink.finish(sink)
    end

    test "a closed sink exposes safe failure to subsequent producers" do
      {:ok, sink} = Sink.open(mode: :memory, max_bytes: 3)
      assert :ok = Sink.discard(sink)
      assert Sink.quota(sink) == nil
      assert :ok = Sink.fail(sink, :late_error)
      assert %{failure: :sink_closed} = Sink.stats(sink)
    end

    test "an unwritable destination reports failure without replacing the existing file", %{
      dir: dir
    } do
      File.mkdir_p!(dir)
      destination = Path.join(dir, "not-a-directory")
      File.write!(destination, "preserved")
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 10, dir: destination)
      assert {:error, {:sink_write_failed, _}} = Sink.start(sink)
      assert File.read!(destination) == "preserved"
    end

    test "rejects invalid configuration" do
      assert {:error, :invalid_sink_quota} = Sink.open(mode: :memory, max_bytes: 0)
      assert {:error, :invalid_sink_mode} = Sink.open(mode: :tape, max_bytes: 1)
      assert {:error, :invalid_sink_dir} = Sink.open(mode: :file, max_bytes: 1)
    end
  end

  describe "ownership" do
    test "discard removes the partial file and is idempotent", %{dir: dir} do
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 100, dir: dir)
      :ok = Sink.write(sink, "partial")
      assert File.ls!(dir) != []
      assert :ok = Sink.discard(sink)
      assert File.ls!(dir) == []
      assert :ok = Sink.discard(sink)
      assert {:error, :sink_closed} = Sink.write(sink, "late")
    end

    test "an unrelated monitor notification does not discard an owned file", %{dir: dir} do
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 100, dir: dir)
      assert :ok = Sink.write(sink, "keep")
      send(sink, {:DOWN, make_ref(), :process, self(), :normal})
      assert {:ok, %{path: path}} = Sink.finish(sink)
      assert File.read!(path) == "keep"
      assert :ok = Sink.release(sink)
    end

    test "owner exit cancels the sink and removes the partial file", %{dir: dir} do
      test = self()

      owner =
        spawn(fn ->
          {:ok, sink} = Sink.open(mode: :file, max_bytes: 100, dir: dir)
          :ok = Sink.write(sink, "partial")
          send(test, {:sink, sink})
          Process.sleep(:infinity)
        end)

      assert_receive {:sink, sink}
      ref = Process.monitor(sink)
      assert File.ls!(dir) != []

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^sink, :normal}, 5_000
      assert File.ls!(dir) == []
    end

    test "a producer on another process writes to the owner's sink with acknowledged chunks",
         %{dir: dir} do
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 1_000, dir: dir)

      Task.await(
        Task.async(fn ->
          for _ <- 1..10, do: :ok = Sink.write(sink, String.duplicate("a", 100))
        end)
      )

      assert %{size: 1_000, writes: 10, max_chunk: 100} = Sink.stats(sink)
      assert {:ok, %{path: path}} = Sink.finish(sink)
      assert File.stat!(path).size == 1_000
    end

    test "an empty file can be finished and handed over", %{dir: dir} do
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 10, dir: dir)
      assert {:ok, %{path: path, size: 0}} = Sink.finish(sink)
      assert File.read!(path) == ""
      assert {:error, :sink_finished} = Sink.start(sink)
      assert :ok = Sink.release(sink)
    end

    test "starting a file twice keeps the existing partial bytes", %{dir: dir} do
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 10, dir: dir)
      assert :ok = Sink.start(sink)
      assert :ok = Sink.write(sink, "abc")
      assert :ok = Sink.start(sink)
      assert {:ok, %{path: path, size: 3}} = Sink.finish(sink)
      assert File.read!(path) == "abc"
      assert :ok = Sink.release(sink)
    end

    test "a finished file stays with the sink until the caller releases it", %{dir: dir} do
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 100, dir: dir)
      :ok = Sink.write(sink, "kept")
      {:ok, %{path: path, size: 4}} = Sink.finish(sink)

      # Finished, but not yet handed over: still owned, closed to further writes.
      assert Process.alive?(sink)
      assert File.read!(path) == "kept"
      assert {:error, :sink_finished} = Sink.write(sink, "more")
      assert {:error, :sink_finished} = Sink.finish(sink)

      ref = Process.monitor(sink)
      assert :ok = Sink.release(sink)
      assert_receive {:DOWN, ^ref, :process, ^sink, _}, 1_000
      assert File.read!(path) == "kept"
    end

    test "owner exit between finish and release removes the finished file", %{dir: dir} do
      test = self()

      owner =
        spawn(fn ->
          {:ok, sink} = Sink.open(mode: :file, max_bytes: 100, dir: dir)
          :ok = Sink.write(sink, "completed")
          {:ok, %{path: path}} = Sink.finish(sink)
          send(test, {:finished, sink, path})
          Process.sleep(:infinity)
        end)

      assert_receive {:finished, sink, path}, 5_000
      ref = Process.monitor(sink)
      assert File.exists?(path)

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^sink, :normal}, 5_000
      refute File.exists?(path)
    end

    test "discarding a finished file removes it", %{dir: dir} do
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 100, dir: dir)
      :ok = Sink.write(sink, "gone")
      {:ok, %{path: path}} = Sink.finish(sink)

      assert :ok = Sink.discard(sink)
      refute File.exists?(path)
      assert {:error, :sink_closed} = Sink.release(sink)
    end

    test "release before finish is refused and removes nothing", %{dir: dir} do
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 100, dir: dir)
      :ok = Sink.write(sink, "partial")

      assert {:error, :not_finished} = Sink.release(sink)
      assert Process.alive?(sink)
      assert [_part] = File.ls!(dir)
      Sink.discard(sink)
    end

    test "own_dir cleanup also covers a file renamed inside the directory", %{dir: dir} do
      owned = Path.join(dir, "owned")
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 100, dir: owned, own_dir: true)
      :ok = Sink.write(sink, "x")
      {:ok, %{path: path}} = Sink.finish(sink)
      renamed = Path.join(owned, "final.md")
      :ok = File.rename(path, renamed)

      Sink.discard(sink)
      refute File.exists?(renamed)
      refute File.exists?(owned)
    end

    test "own_dir keeps the directory after release", %{dir: dir} do
      owned = Path.join(dir, "owned")
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 100, dir: owned, own_dir: true)
      :ok = Sink.write(sink, "x")
      {:ok, %{path: path}} = Sink.finish(sink)
      :ok = Sink.release(sink)

      assert File.read!(path) == "x"
    end
  end

  describe "classification and memory mode" do
    test "memory mode joins chunks under the same quota" do
      {:ok, sink} = Sink.open(mode: :memory, max_bytes: 6)
      :ok = Sink.write(sink, ["ab", "cd"])
      assert {:error, {:materialization_limit, 6}} = Sink.write(sink, "efg")

      {:ok, exact} = Sink.open(mode: :memory, max_bytes: 6)
      :ok = Sink.write(exact, "abc")
      :ok = Sink.write(exact, "def")
      assert {:ok, %{binary: "abcdef", size: 6, text?: true}} = Sink.finish(exact)
    end

    test "text is recognised across chunk boundaries that split a character" do
      <<a::binary-size(1), b::binary>> = "é"
      {:ok, sink} = Sink.open(mode: :memory, max_bytes: 100)
      :ok = Sink.write(sink, "x" <> a)
      :ok = Sink.write(sink, b <> "y")
      assert {:ok, %{binary: "xéy", text?: true}} = Sink.finish(sink)
    end

    test "NUL bytes, invalid UTF-8 and a truncated tail are binary" do
      for data <- [[<<0, 1>>], [<<255, 254>>], ["ok", <<0xC3>>]] do
        {:ok, sink} = Sink.open(mode: :memory, max_bytes: 100)
        Enum.each(data, &Sink.write(sink, &1))
        assert {:ok, %{text?: false}} = Sink.finish(sink)
      end
    end

    test "an empty started body is distinguishable from no body" do
      {:ok, sink} = Sink.open(mode: :memory, max_bytes: 5)
      assert %{started?: false} = Sink.stats(sink)
      :ok = Sink.start(sink, 0)
      assert %{started?: true, size: 0} = Sink.stats(sink)
      assert {:ok, %{binary: "", size: 0}} = Sink.finish(sink)
    end
  end
end
