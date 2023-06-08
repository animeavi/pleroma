defmodule Pleroma.SQLiteRepo.Migrations.AddObanSqliteJobsTable do
  use Ecto.Migration

  defdelegate up, to: Oban.Migrations
  defdelegate down, to: Oban.Migrations
end
