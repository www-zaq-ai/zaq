defmodule Mix.Tasks.Test.Fast do
  use Mix.Task

  @shortdoc "Runs the test suite in isolated OS process partitions"
  @preferred_cli_env :test

  @moduledoc """
  Runs `mix test` in two OS processes by default, with a separate test database
  for each process through `MIX_TEST_PARTITION`.

      mix test.fast --seed 12345

  Set `TEST_PARTITIONS` to change the process count and `TEST_MAX_CASES` to
  change ExUnit concurrency within each process. Test arguments are forwarded
  to every partition. An explicit test path runs in one process because Mix
  rejects a partition with no matching files. Test output streams while the
  suite runs. After all partitions finish, a final result reports success or
  failure.

  This command does not merge partitioned coverage reports. Use the existing
  coverage commands for coverage validation.
  """

  @impl Mix.Task
  def run(args) do
    requested_partitions = positive_env("TEST_PARTITIONS", 2)
    partitions = if Enum.any?(args, &test_path?/1), do: 1, else: requested_partitions
    max_cases = positive_env("TEST_MAX_CASES", 8)
    mix = System.find_executable("mix") || Mix.raise("mix executable not found")
    started = System.monotonic_time(:millisecond)

    compile!(mix)

    results =
      1..partitions
      |> Task.async_stream(
        fn partition -> run_partition(mix, partition, partitions, max_cases, args) end,
        max_concurrency: partitions,
        timeout: :infinity
      )
      |> Enum.to_list()

    failures =
      results
      |> Enum.with_index(1)
      |> Enum.flat_map(&report_partition/1)

    seconds = Float.round((System.monotonic_time(:millisecond) - started) / 1000, 1)

    if failures == [] do
      Mix.shell().info("test.fast passed: #{partitions}/#{partitions} partitions in #{seconds}s")
    else
      Mix.raise(
        "test.fast failed: #{length(failures)}/#{partitions} partitions in #{seconds}s " <>
          "(#{Enum.join(failures, ", ")})"
      )
    end
  end

  defp positive_env(name, default) do
    value = System.get_env(name, Integer.to_string(default))

    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> Mix.raise("#{name} must be a positive integer")
    end
  end

  defp test_path?(arg), do: arg == "test" or String.starts_with?(arg, "test/")

  defp compile!(mix) do
    {output, status} =
      System.cmd(mix, ["compile"], env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

    if status != 0 do
      Mix.raise("test.fast compilation failed:\n#{tail(output)}")
    end
  end

  defp run_partition(mix, partition, partitions, max_cases, args) do
    System.cmd(
      mix,
      [
        "test",
        "--partitions",
        to_string(partitions),
        "--max-cases",
        to_string(max_cases),
        "--color" | args
      ],
      env: [{"MIX_ENV", "test"}, {"MIX_TEST_PARTITION", to_string(partition)}],
      stderr_to_stdout: true,
      into: IO.stream()
    )
  end

  defp report_partition({{:ok, {_stream, 0}}, _partition}), do: []

  defp report_partition({{:ok, {_stream, status}}, partition}) do
    Mix.shell().error("Partition #{partition} exited #{status}")
    ["#{partition} exited #{status}"]
  end

  defp report_partition({{:exit, reason}, partition}) do
    Mix.shell().error("Partition #{partition} crashed: #{inspect(reason)}")
    ["#{partition} crashed"]
  end

  defp tail(output) do
    output
    |> String.split("\n")
    |> Enum.take(-40)
    |> Enum.join("\n")
  end
end
