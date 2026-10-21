defmodule Zaq.TestSupport.HistoryBrowser do
  @moduledoc """
  Runs browser history journeys over an ephemeral real Endpoint in SQL Sandbox.

  Private process checkpoints coordinate real ingress with the browser. This
  helper does not reset databases, expose public test endpoints or mock services.
  """

  import ExUnit.Assertions

  def run!(opts, checkpoint \\ fn _stage, state -> {%{}, state} end) do
    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: ZaqWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    executable =
      System.find_executable("node") || flunk("Node.js is required for browser history")

    browser =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          Map.get(opts, :runner, "test/e2e/support/channel-history-browser.cjs"),
          "http://localhost:#{port}"
        ]
      ])

    Port.command(browser, Jason.encode!(opts) <> "\n")

    try do
      await_browser(browser, checkpoint, %{}, "", "")
    after
      if Port.info(browser), do: Port.close(browser)
    end
  end

  defp await_browser(port, checkpoint, state, output, buffer) do
    receive do
      {^port, {:data, data}} ->
        lines = String.split(buffer <> data, "\n")

        state =
          Enum.reduce(Enum.drop(lines, -1), state, fn line, current ->
            case Jason.decode(line) do
              {:ok, %{"checkpoint" => stage}} ->
                {reply, next} = checkpoint.(stage, current)
                Port.command(port, Jason.encode!(reply) <> "\n")
                next

              _ ->
                current
            end
          end)

        await_browser(port, checkpoint, state, output <> data, List.last(lines))

      {^port, {:exit_status, 0}} ->
        assert output =~ "history journey passed"
        state

      {^port, {:exit_status, status}} ->
        flunk("History browser exited #{status}: #{output}")
    after
      60_000 -> flunk("History browser timed out: #{output}")
    end
  end
end
