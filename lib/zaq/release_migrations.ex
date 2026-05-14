defmodule Zaq.Release do
  @moduledoc """
  This module is in charge of exposing methods to handle DB tasks on released environment
  where mix is not available
  """
  @app :zaq

  def migrate do
    {:ok, _} = Application.ensure_all_started(:ssl)

    for repo <- repos() do
      case Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true)) do
        {:ok, _migrated, _apps} -> :ok
      end
    end
  end

  def rollback(repo, version) do
    {:ok, _} = Application.ensure_all_started(:ssl)
    Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    case Application.load(@app) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end

    Application.fetch_env!(@app, :ecto_repos)
  end
end
