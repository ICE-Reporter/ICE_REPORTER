defmodule IceReporter.Repo.Migrations.CreateReports do
  use Ecto.Migration

  def change do
    create table(:reports) do
      add :type, :string, null: false
      add :description, :text
      add :latitude, :float, null: false
      add :longitude, :float, null: false
      add :location_description, :string
      add :expires_at, :utc_datetime
      add :is_active, :boolean, default: true

      timestamps()
    end

    create index(:reports, [:type])
    create index(:reports, [:is_active])
    create index(:reports, [:expires_at])
    create index(:reports, [:latitude, :longitude])
  end
end
