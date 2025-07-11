# ICE Reporter - Emergency Alert Style App Plan

## High-Level Plan
- [x] Generate a Phoenix LiveView project called `ice_reporter`
- [x] Start the server and create our plan.md
- [ ] Replace the default home page with urgent & bold emergency alert style static mockup
- [ ] Implement the core reporting functionality:
  - [ ] Create ReportLive with real-time map integration using JavaScript
  - [ ] Add Report schema/migration for storing reports (location, type, timestamp, description)
  - [ ] Implement the Reports context for CRUD operations
  - [ ] Create the report template with interactive map and reporting form
- [ ] Add real-time features with PubSub for live report updates across all users
- [ ] Update layouts to match our urgent & bold emergency alert design:
  - [ ] Update root.html.heex with emergency theme (forced dark theme for urgency)
  - [ ] Update <Layouts.app> component with bold red/orange alert styling
  - [ ] Update app.css with emergency alert color scheme and bold typography
- [ ] Update router with our new routes (remove placeholder home route)
- [ ] Visit the app to verify everything works
- [ ] Reserve 2-3 steps for debugging and polish

## Design Specifications - Urgent & Bold Emergency Alert Style
- **Color Scheme**: Dark background with bright red/orange accents for alerts
- **Typography**: Bold, high-contrast fonts for maximum readability
- **UI Elements**: Large buttons, clear icons, emergency-style borders
- **Map Integration**: Real-time plotting of ICE activity reports
- **Report Types**: Checkpoints, Raids, Patrol Activity, Detention Centers
- **Features**: Anonymous reporting, time-based expiration, real-time updates

## Technical Implementation
- LiveView with PubSub for real-time updates
- JavaScript map integration (Leaflet or similar)
- SQLite database for report storage
- Emergency alert styling with high contrast ratios
