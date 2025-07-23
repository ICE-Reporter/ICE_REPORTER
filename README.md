# ICE Reporter

🐻‍❄️ A real-time community reporting system for ICE (Immigration and Customs Enforcement) activity.

## ⚠️ **Development Status**

**This application is currently under active development and is NOT intended for production use or actual community reporting efforts at this time.**

- 🚧 **Work in Progress**: Core features are being developed and tested
- 🔧 **Breaking Changes**: The application may undergo significant changes
- 📊 **Testing Phase**: Currently used for development and testing purposes only
- 🚫 **Not for Real Reports**: Do not use for actual ICE activity reporting yet

For updates on production readiness, please monitor this repository or check with the maintainers.

[![Deploy to Fly.io](https://fly.io/static/images/launch-button.svg)](https://fly.io/launch?template=https://github.com/yourusername/ice_reporter)

## Overview

ICE Reporter is an anonymous, real-time community safety platform that allows users to report ICE activity including checkpoints, operations, patrols, and detention facilities. The application prioritizes user privacy, requires no registration, and provides immediate community-wide visibility of reports through an interactive map interface.

## Features

### 🗺️ Interactive Map Reporting
- **One-click reporting**: Click anywhere on the map to report ICE activity
- **Real-time updates**: Reports appear instantly across all connected users
- **Geographic validation**: Ensures reports are within the continental United States
- **Activity types**: Checkpoint, Operation, Patrol, and Detention Facility reporting

### 🔍 Address Search & Navigation
- **Smart autocomplete**: Type any address to quickly navigate the map
- **Keyboard navigation**: Arrow keys and Enter for accessibility
- **US-focused results**: Prioritizes locations within the United States

### 🔒 Privacy & Security
- **Completely anonymous**: No user accounts, login, or personal information required
- **Smart rate limiting**: 3 reports per 10 minutes with browser fingerprinting for enhanced spam protection
- **hCaptcha integration**: Automated verification for sustained reporting
- **Captcha failure cleanup**: Automatically removes all reports from users who fail verification
- **Data minimization**: Only essential geographic and temporal data is stored in database
- **Temporary tracking**: Browser fingerprints stored only in server memory, auto-expire after 30 minutes

### ⚡ Real-time Experience
- **Live updates**: Phoenix LiveView provides instant report broadcasting
- **Responsive design**: Works seamlessly on desktop and mobile devices
- **Auto-expiration**: Reports automatically expire after 4 hours

### 🌍 Language Support
- **Bilingual interface**: Full English/Spanish language toggle
- **Instant switching**: Language changes without page reload
- **Comprehensive translations**: All UI elements, buttons, and messages translated

## Tech Stack

### Backend
- **[Phoenix Framework](https://phoenixframework.org/)**: Modern web framework for Elixir
- **[Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)**: Real-time server-rendered HTML
- **[Ecto](https://hexdocs.pm/ecto/)**: Database wrapper and query generator
- **[SQLite](https://sqlite.org/)**: Embedded database for simplicity and portability
- **[castore](https://hex.pm/packages/castore)**: SSL certificate store for HTTPS requests

### Frontend
- **[TailwindCSS](https://tailwindcss.com/)**: Utility-first CSS framework
- **[Leaflet.js](https://leafletjs.com/)**: Interactive map library
- **[OpenStreetMap](https://www.openstreetmap.org/)**: Free map tiles and geocoding

### Services
- **[Nominatim](https://nominatim.openstreetmap.org/)**: Address search and reverse geocoding
- **[hCaptcha](https://www.hcaptcha.com/)**: Privacy-focused captcha verification
- **[Fly.io](https://fly.io/)**: Application deployment platform

## How It Works

### Report Creation Process
1. **User clicks** on the interactive map at any location
2. **Report type selection** popup appears with four options:
   - 🛑 **Checkpoint**: Traffic stops and document checks
   - 🏠 **Operation**: Raids and enforcement actions
   - 👮 **Patrol**: Routine ICE patrol activity
   - 🧊 **Facility**: Detention centers and processing facilities

3. **Instant submission** with immediate visual feedback
4. **Address resolution** happens asynchronously via OpenStreetMap
5. **Real-time broadcast** to all connected users via Phoenix PubSub
6. **Automatic expiration** after 4 hours

### Rate Limiting & Anti-Abuse
- **3 reports per 10 minutes** per IP address/browser fingerprint
- **hCaptcha verification** required for additional reports
- **Captcha failure cleanup** automatically removes all reports from users who fail verification
- **Geographic validation** prevents ocean/invalid coordinate reports
- **Duplicate detection** blocks exact coordinate matches within 1 hour
- **Continental US bounds** enforcement

## Trust & Privacy

### Data Collection
ICE Reporter follows strict data minimization principles:

```elixir
# Only this data is stored per report:
%{
  type: "checkpoint" | "raid" | "patrol" | "detention",
  description: "Reported via map click",
  latitude: 40.7128,
  longitude: -74.0060,
  location_description: "123 Main St, New York, NY",
  expires_at: ~U[2024-01-02 15:30:00Z],
  is_active: true,
  inserted_at: ~U[2024-01-01 15:30:00Z],
  updated_at: ~U[2024-01-01 15:30:00Z]
}
```

### What We Don't Store
- ❌ **No user accounts** or personal information
- ❌ **No IP addresses** in the database
- ❌ **No browser fingerprints** in the database (only temporarily in memory)
- ❌ **No session tracking** beyond anti-spam measures
- ❌ **No analytics** or third-party tracking
- ❌ **No email** or contact information

### Security Measures
- **HTTPS support** via deployment platform (Fly.io handles SSL termination)
- **Content Security Policy** headers
- **Rate limiting** to prevent abuse
- **Input validation** and sanitization
- **Geographic bounds** checking
- **Automatic data expiration** (4 hours)

### Rate Limiting & Anti-Spam Details
The rate limiter uses an in-memory GenServer that:
- Tracks submission counts per IP/fingerprint (expires after 10 minutes)
- Temporarily tracks report IDs for captcha failure cleanup (expires after 30 minutes)
- Resets after successful hCaptcha verification
- Removes all reports from users who fail captcha verification
- Does not persist rate limiting data to the database

### Data Cleanup Schedule
- **Memory cleanup**: Every 5 minutes (removes expired rate limits and tracking data)
- **Database cleanup**: Every 30 minutes (removes reports older than 4 hours)
- **Report expiration**: 4 hours (reports disappear from map)
- **Rate limit reset**: 10 minutes (users can report again)
- **Captcha tracking**: 30 minutes (cleanup tracking expires)

## Development Setup

### Prerequisites
- **Elixir 1.15+** with OTP 26+
- **Node.js 18+** for asset compilation
- **Git** for version control

### Installation
```bash
# Clone the repository
git clone https://github.com/yourusername/ice_reporter.git
cd ice_reporter

# Install dependencies
mix setup

# Start the development server
mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000) to see the application.

### Development Commands
```bash
# Install dependencies
mix deps.get

# Set up database
mix ecto.setup

# Run tests
mix test

# Build assets
mix assets.build

# Interactive console
iex -S mix phx.server
```

### Environment Variables
For production deployment, configure:
```bash
SECRET_KEY_BASE="your-secret-key-here"
DATABASE_PATH="/data/ice_reporter.db"
PHX_HOST="your-domain.com"
PORT="8080"
HCAPTCHA_SITE_KEY="your-site-key"
HCAPTCHA_SECRET="your-secret-key"
```

## Database Schema

### Reports Table
```sql
CREATE TABLE reports (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT NOT NULL,                    -- "checkpoint", "raid", "patrol", "detention"
  description TEXT,                      -- "Reported via map click"
  latitude REAL NOT NULL,                -- Decimal degrees
  longitude REAL NOT NULL,               -- Decimal degrees
  location_description TEXT,             -- "123 Main St, New York, NY"
  expires_at DATETIME,                   -- UTC timestamp, 4 hours from creation
  is_active BOOLEAN DEFAULT true,        -- Soft deletion flag
  inserted_at DATETIME NOT NULL,         -- UTC timestamp
  updated_at DATETIME NOT NULL           -- UTC timestamp
);

-- Indexes for performance
CREATE INDEX idx_reports_type ON reports(type);
CREATE INDEX idx_reports_active ON reports(is_active);
CREATE INDEX idx_reports_expires ON reports(expires_at);
CREATE INDEX idx_reports_location ON reports(latitude, longitude);
```

### Data Lifecycle
- **Creation**: Reports are created with coordinates and type
- **Address Resolution**: Location descriptions are added asynchronously
- **Expiration**: Reports automatically expire after 4 hours
- **Cleanup**: Expired reports remain in database for historical purposes but are filtered from queries

## Project Structure

```
ice_reporter/
├── lib/
│   ├── ice_reporter/
│   │   ├── application.ex           # OTP application
│   │   ├── repo.ex                  # Database repository
│   │   ├── report.ex                # Report schema
│   │   ├── reports.ex               # Report context
│   │   └── rate_limiter.ex          # Rate limiting GenServer
│   └── ice_reporter_web/
│       ├── controllers/             # HTTP controllers
│       ├── live/
│       │   ├── report_live.ex       # Main LiveView
│       │   └── report_live.html.heex # Template
│       ├── components/              # UI components
│       ├── router.ex                # URL routing
│       └── endpoint.ex              # Web endpoint
├── assets/
│   ├── css/
│   │   └── app.css                  # Tailwind styles
│   └── js/
│       └── app.js                   # Frontend JavaScript
├── config/
│   ├── config.exs                   # Base configuration
│   ├── dev.exs                      # Development config
│   ├── prod.exs                     # Production config
│   └── runtime.exs                  # Runtime configuration
├── priv/
│   ├── repo/migrations/             # Database migrations
│   └── static/                      # Static assets
├── test/                            # Test files
├── fly.toml                         # Fly.io deployment config
├── Dockerfile                       # Container configuration
└── mix.exs                          # Project dependencies
```

## Deployment

### Fly.io Deployment
1. **Install Fly CLI**: `curl -L https://fly.io/install.sh | sh`
2. **Login**: `flyctl auth login`
3. **Deploy**: `flyctl deploy`

### Environment Setup
```bash
# Set required secrets
flyctl secrets set SECRET_KEY_BASE="$(mix phx.gen.secret)"
flyctl secrets set HCAPTCHA_SITE_KEY="your-site-key"
flyctl secrets set HCAPTCHA_SECRET="your-secret-key"

# Create persistent volume for database
# Note: Replace 'ord' with your desired region (e.g., sea, iad, lax)
# Region must match primary_region in fly.toml
flyctl volumes create ice_reporter_data --region ord --size 1
```

### Production Checklist
- [ ] Set strong `SECRET_KEY_BASE`
- [ ] Configure production hCaptcha keys
- [ ] Set up persistent volume for SQLite database
- [ ] Ensure castore dependency for SSL certificates
- [ ] Configure custom domain (optional)
- [ ] Test rate limiting and captcha flow
- [ ] Configure HTTPS at deployment platform level (Fly.io handles this automatically)
- [ ] Monitor application logs

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Roadmap & TODOs

### 🚨 Alert System
- **Community Notifications**: Implement user alert system for new ICE activity reports
- **Multi-channel approach**: Considering Bluesky integration, web push notifications, and RSS feeds
- **Privacy-first**: Maintain anonymous approach while enabling community awareness

### 🚀 CI/CD Pipeline
- **Staging Environment**: Set up dedicated staging instance for testing features
- **Branching Strategy**: Implement proper Git workflow (main/develop/feature branches)
- **Semantic Versioning**: Add automated versioning and release management
- **Automated Testing**: Comprehensive CI/CD with GitHub Actions
- **Deployment Automation**: Separate staging and production deployment pipelines

## Support

For issues and feature requests, please use the [GitHub Issues](https://github.com/yourusername/ice_reporter/issues) page.

---

**Important**: This application is designed for legitimate community safety purposes. Please use responsibly and in accordance with local laws and regulations.