defmodule Mix.Tasks.Hooks.Verify do
  use Mix.Task

  @shortdoc "Verifies hook events are uniquely dispatched and all documented in Zaq.Hooks"

  @moduledoc """
  Scans `lib/` for `dispatch_sync/3` and `dispatch_async/3` call sites,
  extracts the event atom from each, then enforces two rules:

    1. **Uniqueness** — each event atom appears in at most one dispatch call site.
    2. **Coverage** — every dispatched event atom is listed in `Zaq.Hooks.documented_events/0`.

  Add to your precommit alias in `mix.exs` to gate commits on compliance.

  ## Usage

      mix hooks.verify

  Exits non-zero on any violation.

  ## Known limitations

  The source scan uses a regex (`dispatch_(?:sync|async)\\(\\s*:(\\w+)`) that
  only captures *literal* event atoms as the first argument. Calls that pass the
  event as a variable or build it dynamically are not detected:

      event = :my_event
      Hooks.dispatch_sync(event, payload, ctx)   # NOT detected

  Always use a literal atom as the first argument to `dispatch_sync/3` and
  `dispatch_async/3`.
  """

  @impl Mix.Task
  def run(_args) do
    mix_task_module = Application.get_env(:zaq, :hooks_verify_mix_task_module, Mix.Task)

    try do
      mix_task_module.run("compile", [])
      mix_task_module.run("app.start")
    rescue
      e in Mix.Error ->
        Mix.shell().error("Failed to start application: #{Exception.message(e)}")
        exit({:shutdown, 1})
    end

    documented = Zaq.Hooks.documented_events()
    dispatch_sites = find_dispatch_sites()

    uniqueness_errors =
      dispatch_sites
      |> Enum.map(fn {event, file} -> {event, file} end)
      |> Enum.uniq()
      |> Enum.group_by(fn {event, _file} -> event end, fn {_event, file} -> file end)
      |> Enum.filter(fn {_event, files} -> length(files) > 1 end)
      |> Enum.map(fn {event, files} ->
        "Event :#{event} dispatched from multiple modules:\n" <>
          Enum.map_join(files, "\n", &"  - #{&1}")
      end)

    dispatched_events =
      dispatch_sites |> Enum.map(fn {event, _} -> event end) |> Enum.uniq()

    coverage_errors =
      dispatched_events
      |> Enum.reject(&(&1 in documented))
      |> Enum.map(fn event ->
        "Event :#{event} is dispatched but not documented in Zaq.Hooks"
      end)

    all_errors = uniqueness_errors ++ coverage_errors

    if all_errors == [] do
      Mix.shell().info("hooks.verify passed — #{length(dispatched_events)} event(s) OK")
    else
      Enum.each(all_errors, fn msg -> Mix.shell().error(msg) end)
      Mix.raise("hooks.verify failed with #{length(all_errors)} violation(s)")
    end
  end

  # Scans lib/**/*.ex for dispatch_sync/dispatch_async calls and returns
  # a list of {event_atom, file_path} tuples.
  defp find_dispatch_sites do
    glob = Application.get_env(:zaq, :hooks_verify_glob, "lib/**/*.ex")

    Path.wildcard(glob)
    |> Enum.flat_map(&scan_file/1)
  end

  # Exposed for testing. Returns [{event_atom, file_path}] from a single file.
  @doc false
  def scan_file(path) do
    content = File.read!(path)

    ~r/dispatch_(?:sync|async)\(\s*:(\w+)/
    |> Regex.scan(content)
    |> Enum.map(fn [_full, event] -> {String.to_atom(event), path} end)
  end
end
