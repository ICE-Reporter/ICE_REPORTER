defmodule IceReporterWeb.PageController do
  use IceReporterWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
