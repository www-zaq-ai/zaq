defmodule Zaq.Release do
  @moduledoc """
  This module is in charge of exposing methods to handle DB tasks on released environment
  where mix is not available
  """
  @app :zaq

  def migrate do
    {:ok, _} = Application.ensure_all_started(:ssl)

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    {:ok, _} = Application.ensure_all_started(:ssl)

    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.load(@app)
    Application.fetch_env!(@app, :ecto_repos)
  end
end
