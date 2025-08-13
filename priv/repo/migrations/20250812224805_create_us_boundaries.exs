defmodule IceReporter.Repo.Migrations.CreateUsBoundaries do
  use Ecto.Migration

  def change do
    create table(:us_boundaries) do
      add :name, :string
      add :state_code, :string
      add :geometry_type, :string, null: false
      add :coordinates, :text, null: false  # Store GeoJSON coordinates as JSON text
      add :bbox, :text  # Bounding box for faster filtering [min_lng, min_lat, max_lng, max_lat]
      
      timestamps()
    end
    
    create index(:us_boundaries, [:geometry_type])
    create index(:us_boundaries, [:state_code])
  end
end
