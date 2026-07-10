defmodule Zaq.System.CommandTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Zaq.System.Command

  # Writes a temporary executable and returns its absolute path so run/3
  # exercises the real Port path without depending on any installed tool.
  defp fake_bin(body) do
    path = Path.join(System.tmp_dir!(), "zaq_command_fake_#{System.unique_integer([:positive])}")
    File.write!(path, body)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  # Prints each received argument on its own line — lets tests assert exact,
  # unsplit argument passing.
  defp echo_args_bin, do: fake_bin(~s(#!/bin/sh\nfor a in "$@"; do echo "$a"; done\n))

  describe "run/3 success" do
    test "returns trimmed stdout on exit 0" do
      bin = echo_args_bin()

      assert {:ok, output} = Command.run(bin, ["hello", "world"])
      assert output == "hello\nworld"
    end

    test "passes each argument as a separate process arg (no shell interpretation)" do
      bin = echo_args_bin()

      injection = "@e2; rm -rf /"
      assert {:ok, output} = Command.run(bin, ["fill", injection])
      assert injection in String.split(output, "\n")
    end

    test "keeps output whose final line has no trailing newline" do
      # `printf` without a trailing \n arrives as a :noeol-equivalent chunk and
      # must not be dropped when the process exits.
      bin = fake_bin(~s(#!/bin/sh\nprintf 'no-newline-tail'\n))

      assert {:ok, "no-newline-tail"} = Command.run(bin, [])
    end

    test "runs a bare executable name resolved on PATH" do
      # `true` exits 0 with no output; proves PATH resolution (not just abs paths).
      assert {:ok, ""} = Command.run("true", [])
    end
  end

  describe "run/3 failures" do
    test "maps a non-zero exit to an error tuple with the code and output" do
      bin = fake_bin(~s(#!/bin/sh\necho boom\nexit 3\n))

      assert {:error, %{exit_code: 3, output: output}} = Command.run(bin, ["x"])
      assert output =~ "boom"
    end

    test "preserves an unterminated trailing line on a non-zero exit too" do
      bin = fake_bin(~s(#!/bin/sh\nprintf 'partial-error'\nexit 2\n))

      assert {:error, %{exit_code: 2, output: "partial-error"}} = Command.run(bin, [])
    end

    test "returns :enoent when the executable is not found" do
      assert {:error, %{exit_code: :enoent, output: output}} =
               Command.run("/nonexistent/zaq-command-xyz", [])

      assert output =~ "not found"
    end

    test "returns :timeout when the command exceeds the timeout" do
      bin = fake_bin(~s(#!/bin/sh\nsleep 5\n))

      assert {:error, %{exit_code: :timeout}} = Command.run(bin, [], timeout_ms: 50)
    end
  end

  describe "captured combined output" do
    test "stderr is merged into stdout" do
      bin = fake_bin(~s(#!/bin/sh\necho out\necho err 1>&2\n))

      assert {:ok, output} = Command.run(bin, [])
      assert output =~ "out"
      assert output =~ "err"
    end
  end
end
