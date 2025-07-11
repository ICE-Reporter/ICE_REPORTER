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
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
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

// Mapbox integration for ICE Reporter
let mapboxMap = null;

// Initialize Mapbox when the page loads
window.addEventListener("DOMContentLoaded", () => {
  initializeMapbox();
});

function initializeMapbox() {
  const mapContainer = document.getElementById("map-container");
  if (!mapContainer) return;

  // Create Mapbox map
  mapboxgl.accessToken =
    "pk.eyJ1IjoiaWNlcmVwb3J0ZXIiLCJhIjoiY2xqNjR5cDJkMDBmZDNxbzBxdmNkZTVtayJ9.demo_token"; // Demo token - replace with real one

  mapboxMap = new mapboxgl.Map({
    container: mapContainer,
    style: "mapbox://styles/mapbox/streets-v12",
    center: [-74.006, 40.7128], // NYC coordinates
    zoom: 10,
  });

  // Add click handler for placing reports
  mapboxMap.on("click", (e) => {
    const { lng, lat } = e.lngLat;

    // Update hidden form fields
    const latInput = document.getElementById("report_latitude");
    const lngInput = document.getElementById("report_longitude");
    if (latInput) latInput.value = lat;
    if (lngInput) lngInput.value = lng;

    // Add temporary marker
    new mapboxgl.Marker({ color: "#ff3366" })
      .setLngLat([lng, lat])
      .addTo(mapboxMap);

    console.log(`Selected location: ${lat}, ${lng}`);
  });
}

// Function to add report markers
function addReportMarker(lat, lng, type) {
  if (!mapboxMap) return;

  const color = getMarkerColor(type);
  new mapboxgl.Marker({ color }).setLngLat([lng, lat]).addTo(mapboxMap);
}

function getMarkerColor(type) {
  switch (type) {
    case "checkpoint":
      return "#ff3366";
    case "raid":
      return "#ff6b35";
    case "patrol":
      return "#3366ff";
    case "detention":
      return "#8b5cf6";
    default:
      return "#6b7280";
  }
}

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
