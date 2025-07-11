defmodule IceReporter.Report do
  use Ecto.Schema
  import Ecto.Changeset

  schema "reports" do
    field :type, :string
    field :description, :string
    field :latitude, :float
    field :longitude, :float
    field :location_description, :string
    field :expires_at, :utc_datetime
    field :is_active, :boolean, default: true

    timestamps()
  end

  @doc false
  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :type,
      :description,
      :latitude,
      :longitude,
      :location_description,
      :expires_at,
      :is_active
    ])
    |> validate_required([:type, :latitude, :longitude])
    |> validate_inclusion(:type, ["checkpoint", "raid", "patrol", "detention"])
    |> validate_number(:latitude, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:longitude, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> put_expires_at()
  end

  defp put_expires_at(changeset) do
    case get_field(changeset, :expires_at) do
      nil ->
        # Default to 24 hours from now
        expires_at =
          DateTime.utc_now() |> DateTime.add(24 * 60 * 60, :second) |> DateTime.truncate(:second)

        put_change(changeset, :expires_at, expires_at)

      _ ->
        changeset
    end
  end
end
