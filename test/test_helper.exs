ExUnit.start(exclude: [:integration])
Ecto.Adapters.SQL.Sandbox.mode(Zaq.Repo, :manual)
Logger.put_module_level(Postgrex.Protocol, :none)
Logger.put_module_level(Task.Supervised, :none)
