// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

// Leaflet integration for ICE Reporter
let leafletMap = null;
let reportPopup = null;

// LiveView hook for map initialization
const Hooks = {
  MapContainer: {
    mounted() {
      console.log("🗺️ Map hook mounted!");
      initializeLeaflet();
    },
    destroyed() {
      if (leafletMap) {
        leafletMap.remove();
        leafletMap = null;
      }
    },
  },
};

// Add hooks to LiveSocket
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

function initializeLeaflet() {
  const mapContainer = document.getElementById("map-container");
  if (!mapContainer) {
    console.log("❌ Map container not found");
    return;
  }

  // Clean up existing map if it exists
  if (leafletMap) {
    leafletMap.remove();
    leafletMap = null;
  }

  console.log("🗺️ Initializing Leaflet map...");

  // Create Leaflet map centered on USA
  leafletMap = L.map(mapContainer, {
    center: [39.8283, -98.5795], // Geographic center of USA
    zoom: 4,
    minZoom: 3,
    maxZoom: 18,
  });

  // Add tile layer - using OpenStreetMap (free, no API key needed)
  L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
    attribution: "© OpenStreetMap contributors",
    maxZoom: 18,
  }).addTo(leafletMap);

  // Set map bounds to roughly USA
  const usaBounds = [
    [20.0, -130.0], // Southwest coordinates
    [50.0, -60.0], // Northeast coordinates
  ];
  leafletMap.setMaxBounds(usaBounds);

  // Add click handler for placing reports
  leafletMap.on("click", function (e) {
    console.log("🗺️ Map clicked at:", e.latlng);
    showReportPopup(e.latlng);
  });

  console.log("✅ Leaflet map initialized successfully!");

  // Expose map globally for submitReport function
  window.leafletMap = leafletMap;
}

function showReportPopup(latlng) {
  if (reportPopup) {
    leafletMap.closePopup(reportPopup);
  }

  const popupContent = `
    <div class="text-center p-2">
      <h3 class="text-lg font-black text-blue-600 mb-3">🧊 Report Activity</h3>
      <div class="grid grid-cols-2 gap-2">
        <button onclick="submitReport('${latlng.lat}', '${latlng.lng}', 'checkpoint')" 
                class="bg-gradient-to-r from-red-500 to-blue-500 text-white px-3 py-2 rounded-xl font-bold hover:scale-105 transition-transform">
          🛑 Checkpoint
        </button>
        <button onclick="submitReport('${latlng.lat}', '${latlng.lng}', 'raid')" 
                class="bg-gradient-to-r from-red-500 to-blue-500 text-white px-3 py-2 rounded-xl font-bold hover:scale-105 transition-transform">
          🏠 Operation
        </button>
        <button onclick="submitReport('${latlng.lat}', '${latlng.lng}', 'patrol')" 
                class="bg-gradient-to-r from-red-500 to-blue-500 text-white px-3 py-2 rounded-xl font-bold hover:scale-105 transition-transform">
          👮 Patrol
        </button>
        <button onclick="submitReport('${latlng.lat}', '${latlng.lng}', 'detention')" 
                class="bg-gradient-to-r from-red-500 to-blue-500 text-white px-3 py-2 rounded-xl font-bold hover:scale-105 transition-transform">
          🧊 Facility
        </button>
      </div>
    </div>
  `;

  reportPopup = L.popup()
    .setLatLng(latlng)
    .setContent(popupContent)
    .openOn(leafletMap);
}

// Function to submit report via LiveView
window.submitReport = function (lat, lng, type) {
  console.log(`🧊 Submitting report: ${type} at ${lat}, ${lng}`);

  // Close the popup
  if (reportPopup) {
    leafletMap.closePopup(reportPopup);
  }

  // Send event to LiveView
  if (window.liveSocket && window.liveSocket.main) {
    window.liveSocket.main.pushEvent("map_report", {
      latitude: parseFloat(lat),
      longitude: parseFloat(lng),
      type: type,
    });
  }

  // Add temporary marker immediately for instant feedback
  addReportMarker(lat, lng, type, true);
};

// Function to add report markers with emojis
function addReportMarker(lat, lng, type, isTemporary = false) {
  if (!leafletMap) return;

  const emoji = getEmojiForType(type);
  const markerColor = isTemporary ? "#fbbf24" : getColorForType(type);

  // Create custom marker with emoji
  const markerIcon = L.divIcon({
    html: `<div style="
      background: ${markerColor}; 
      border: 3px solid white; 
      border-radius: 50%; 
      width: 40px; 
      height: 40px; 
      display: flex; 
      align-items: center; 
      justify-content: center; 
      font-size: 20px;
      box-shadow: 0 4px 12px rgba(0,0,0,0.3);
      ${isTemporary ? "animation: pulse 1s infinite;" : ""}
    ">${emoji}</div>`,
    className: "custom-emoji-marker",
    iconSize: [40, 40],
    iconAnchor: [20, 20],
  });

  const marker = L.marker([lat, lng], { icon: markerIcon }).addTo(leafletMap);

  // Add popup with report info
  marker.bindPopup(`
    <div class="text-center">
      <strong>${emoji} ${getTypeDisplayName(type)}</strong><br>
      <small class="text-gray-600">${isTemporary ? "Submitting..." : "Reported"}</small>
    </div>
  `);

  return marker;
}

function getEmojiForType(type) {
  switch (type) {
    case "checkpoint":
      return "🛑";
    case "raid":
      return "🏠";
    case "patrol":
      return "👮";
    case "detention":
      return "🧊";
    default:
      return "📍";
  }
}

function getColorForType(type) {
  switch (type) {
    case "checkpoint":
      return "#ef4444"; // red
    case "raid":
      return "#f97316"; // orange
    case "patrol":
      return "#3b82f6"; // blue
    case "detention":
      return "#8b5cf6"; // purple
    default:
      return "#6b7280"; // gray
  }
}

function getTypeDisplayName(type) {
  switch (type) {
    case "checkpoint":
      return "Checkpoint";
    case "raid":
      return "Operation";
    case "patrol":
      return "Patrol";
    case "detention":
      return "Facility";
    default:
      return "Report";
  }
}

// Function to load existing reports on the map
window.loadExistingReports = function (reports) {
  if (!leafletMap) return;

  reports.forEach((report) => {
    addReportMarker(report.latitude, report.longitude, report.type, false);
  });
};

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();

      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );

      window.liveReloader = reloader;
    },
  );
}
