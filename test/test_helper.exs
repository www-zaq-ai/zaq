ExUnit.start(exclude: [:integration], capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Zaq.Repo, :manual)
Logger.put_module_level(Postgrex.Protocol, :none)
Logger.put_module_level(Task.Supervised, :none)

# Ensure test/tmp exists and is clean before each run.
# All test-generated temp files live here so they never land in the project root.
File.rm_rf!("test/tmp")
File.mkdir_p!("test/tmp")
Application.put_env(:plug, :upload_tmp_dir, Path.expand("test/tmp"))
