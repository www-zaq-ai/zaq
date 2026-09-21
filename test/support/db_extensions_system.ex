defmodule Zaq.Test.DbExtensionsSystem do
  @moduledoc false

  def find_executable("psql"), do: Process.get(:db_extensions_executable, "/fake/bin/psql")

  def cmd(executable, args, opts) do
    Process.put(:db_extensions_command, {executable, args, opts})
    Process.get(:db_extensions_command_result, {"Database extensions ready.\n", 0})
  end
end
