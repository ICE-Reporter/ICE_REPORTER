defmodule IceReporter.Repo.Migrations.UpdateExistingReportsExpiration do
  use Ecto.Migration
  import Ecto.Query

  def up do
    # Update existing reports to expire 4 hours from their creation time instead of 24 hours
    # This fixes reports created before the expiration change
    execute("""
    UPDATE reports 
    SET expires_at = inserted_at + INTERVAL '4 hours'
    WHERE expires_at > NOW() + INTERVAL '4 hours'
    """)

    # Delete any reports that are already older than 4 hours
    execute("""
    DELETE FROM reports 
    WHERE inserted_at < NOW() - INTERVAL '4 hours'
    """)
  end

  def down do
    # Revert to 24-hour expiration for existing reports
    execute("""
    UPDATE reports 
    SET expires_at = inserted_at + INTERVAL '24 hours'
    WHERE expires_at IS NOT NULL
    """)
  end
end
