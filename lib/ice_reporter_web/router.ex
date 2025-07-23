defmodule IceReporterWeb.Router do
  use IceReporterWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {IceReporterWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self' 'unsafe-inline' https://unpkg.com https://js.hcaptcha.com https://newassets.hcaptcha.com; style-src 'self' 'unsafe-inline' https://unpkg.com; img-src 'self' data: https:; connect-src 'self' wss://localhost:4000 https://nominatim.openstreetmap.org https://hcaptcha.com https://api.hcaptcha.com; frame-src 'self' https://hcaptcha.com https://newassets.hcaptcha.com;"
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", IceReporterWeb do
    pipe_through :browser

    live "/", ReportLive
    live "/reports", ReportLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", IceReporterWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:ice_reporter, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: IceReporterWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
