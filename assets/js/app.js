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
let reportMarkers = new Map(); // Track markers by report ID
let temporaryMarkers = []; // Track temporary markers
let temporaryMarkersByFingerprint = new Map(); // Track temporary markers by fingerprint
let removedReportIds = new Set(); // Track report IDs that have been removed to prevent re-adding
let liveViewSocket = null; // Store the LiveView socket reference
let browserFingerprint = null; // Store browser fingerprint

// Store current language globally
let currentLanguage = 'en';

// US boundary validation now handled server-side via SQLite database

// Server-side validation is authoritative - client-side provides basic sanity checks only

async function isValidUSCoordinate(lat, lng) {
    
    try {
        // Use server-side validation via LiveView event
        return new Promise((resolve) => {
            if (liveViewSocket) {
                // Set up a one-time listener for the validation response
                const handleValidation = (e) => {
                    window.removeEventListener('phx:coordinate_validation_result', handleValidation);
                    const isValid = e.detail.valid;
                    resolve(isValid);
                };
                
                window.addEventListener('phx:coordinate_validation_result', handleValidation);
                
                // Send validation request to server
                liveViewSocket.pushEvent("validate_coordinates", {
                    latitude: lat,
                    longitude: lng
                });
                
                // Fallback timeout in case server doesn't respond
                setTimeout(() => {
                    window.removeEventListener('phx:coordinate_validation_result', handleValidation);
                    resolve(isValidUSCoordinateFallback(lat, lng));
                }, 2000);
            } else {
                resolve(isValidUSCoordinateFallback(lat, lng));
            }
        });
    } catch (error) {
        console.error('Error in server validation:', error);
        return isValidUSCoordinateFallback(lat, lng);
    }
}

// Basic sanity check fallback (server validation is authoritative)
function isValidUSCoordinateFallback(lat, lng) {
    // Basic coordinate range checks for US territory
    // Continental US, Alaska, Hawaii, and territories
    const isValidRange = (
        (lat >= 18.0 && lat <= 72.0 && lng >= -180.0 && lng <= -65.0) // Covers all US territory
    );
    
    if (isValidRange) {
        return true;
    }
    
    return false;
}

// Expose validation function globally for debugging
window.isValidUSCoordinate = isValidUSCoordinate;

// Cache for US boundaries data with persistent browser storage
let cachedUSBoundaries = null;
let usBoundariesLayer = null;
const CACHE_DURATION = 30 * 60 * 1000; // 30 minutes
const CACHE_KEY = 'ice_reporter_boundaries_v1';

// Load boundaries from localStorage cache
function loadBoundariesFromCache() {
    try {
        const cached = localStorage.getItem(CACHE_KEY);
        if (!cached) return null;
        
        const data = JSON.parse(cached);
        const now = Date.now();
        
        if (data.timestamp && (now - data.timestamp) < CACHE_DURATION) {
            return data.boundaries;
        } else {
            // Cache expired, remove it
            localStorage.removeItem(CACHE_KEY);
            return null;
        }
    } catch (error) {
        localStorage.removeItem(CACHE_KEY);
        return null;
    }
}

// Save boundaries to localStorage cache
function saveBoundariesToCache(boundaries) {
    try {
        const data = {
            boundaries: boundaries,
            timestamp: Date.now()
        };
        localStorage.setItem(CACHE_KEY, JSON.stringify(data));
    } catch (error) {
        // Silently handle cache save errors
    }
}

// Load US boundaries from database and display as map layer
function loadUSBoundariesLayer() {
    if (!leafletMap) return;
    
    // Try to load from localStorage first
    const cachedData = loadBoundariesFromCache();
    if (cachedData) {
        cachedUSBoundaries = cachedData;
        addBoundariesToMap(cachedData);
        return;
    }
    
    // If we have a LiveView socket, request fresh data
    if (liveViewSocket) {
        // Request boundary data from server
        liveViewSocket.pushEvent("get_us_boundaries", {});
        
        // Listen for boundary data response
        window.addEventListener('phx:us_boundaries_data', (e) => {
            const boundaries = e.detail.boundaries;
            cachedUSBoundaries = boundaries; // Cache in memory
            saveBoundariesToCache(boundaries); // Save to localStorage
            addBoundariesToMap(boundaries);
        }, { once: true });
    }
}

// Add boundaries to map
function addBoundariesToMap(boundaries) {
    if (!leafletMap || usBoundariesLayer) return;
    
    // Create a layer group for all US boundaries
    usBoundariesLayer = L.layerGroup();
    
    // Simple boundary styling
    const boundaryStyle = {
        color: '#2563eb',
        weight: 1,
        opacity: 0.6,
        fillColor: '#3b82f6',
        fillOpacity: 0.05,
        interactive: false
    };
    
    // Process boundaries
    boundaries.forEach((boundary) => {
        try {
            const coordinates = JSON.parse(boundary.coordinates);
            
            if (boundary.geometry_type === 'Polygon') {
                // Convert GeoJSON to Leaflet format: [lat, lng] instead of [lng, lat]
                const leafletCoordinates = coordinates.map(ring => 
                    ring.map(coord => [coord[1], coord[0]])
                );
                
                const polygon = L.polygon(leafletCoordinates, boundaryStyle);
                usBoundariesLayer.addLayer(polygon);
                
            } else if (boundary.geometry_type === 'MultiPolygon') {
                // Handle MultiPolygon (states with islands)
                coordinates.forEach(polygon => {
                    const leafletCoords = polygon.map(ring => 
                        ring.map(coord => [coord[1], coord[0]])
                    );
                    
                    const multiPoly = L.polygon(leafletCoords, boundaryStyle);
                    usBoundariesLayer.addLayer(multiPoly);
                });
            }
        } catch (error) {
            // Silently handle boundary parsing errors
        }
    });
    
    // Add boundaries to map
    usBoundariesLayer.addTo(leafletMap);
    
}



// Preload US boundaries data for faster map initialization
function preloadUSBoundaries() {
    if (!liveViewSocket || cachedUSBoundaries) return;
    
    
    // Request boundary data from server immediately
    liveViewSocket.pushEvent("get_us_boundaries", {});
    
    // Listen for boundary data response and cache it
    window.addEventListener('phx:us_boundaries_data', (e) => {
        const boundaries = e.detail.boundaries;
        cachedUSBoundaries = boundaries;
    }, { once: true });
}

// Show coordinate error message that auto-disappears
function showCoordinateError(latlng) {
    const isSpanish = currentLanguage === 'es';
    const errorTitle = isSpanish ? '❌ Ubicación No Válida' : '❌ Invalid Location';
    const errorMessage = isSpanish ? 'Los reportes solo pueden crearse dentro de los Estados Unidos' : 'Reports can only be created within the United States';
    
    const errorPopupContent = `
    <div class="text-center p-3" style="z-index: 9999;">
        <h3 class="text-base sm:text-lg font-black text-red-600 mb-2">${errorTitle}</h3>
        <p class="text-sm text-red-500 font-medium">${errorMessage}</p>
    </div>
    `;

    const errorPopup = L.popup({
        closeButton: false,
        autoClose: false,
        closeOnClick: false,
        className: 'error-popup'
    })
    .setLatLng(latlng)
    .setContent(errorPopupContent)
    .openOn(leafletMap);

    // Auto-close after 3 seconds (like the address found popup)
    setTimeout(() => {
        if (errorPopup && leafletMap.hasLayer(errorPopup)) {
            leafletMap.closePopup(errorPopup);
        }
    }, 3000);
}

// LiveView hook for map initialization
const Hooks = {
    MapContainer: {
        mounted() {
            liveViewSocket = this; // Store reference to the LiveView
            currentLanguage = this.el.dataset.language || 'en'; // Get language from data attribute
            
            // Preload boundaries data immediately for faster map loading
            if (!cachedUSBoundaries) {
                preloadUSBoundaries();
            }
            
            initializeLeaflet();
        },
        destroyed() {
            if (leafletMap) {
                leafletMap.remove();
                leafletMap = null;
                reportMarkers.clear();
                temporaryMarkers = []; // Clear temporary markers
                temporaryMarkersByFingerprint.clear(); // Clear fingerprint tracking
                removedReportIds.clear(); // Clear removed IDs tracking
                // Reset boundary cache and layer
                usBoundariesLayer = null;
                cachedUSBoundaries = null;
                // Clear localStorage cache as well
                localStorage.removeItem(CACHE_KEY);
            }
            liveViewSocket = null;
        },
    },
    HCaptcha: {
        mounted() {
            const container = this.el;
            const sitekey = container.dataset.sitekey;

            // Set up 30-second timeout for captcha
            this.captchaTimeout = setTimeout(() => {
                window.location.reload();
            }, 30000);

            // Load hCaptcha script if not already loaded
            if (!window.hcaptcha) {
                const script = document.createElement("script");
                script.src =
                    "https://js.hcaptcha.com/1/api.js?onload=onHCaptchaLoad&render=explicit";
                script.async = true;
                script.defer = true;
                document.head.appendChild(script);

                // Set up global callback
                window.onHCaptchaLoad = () => {
                    this.renderCaptcha(sitekey);
                };
            } else {
                // hCaptcha already loaded
                this.renderCaptcha(sitekey);
            }
        },

        renderCaptcha(sitekey) {
            const container = this.el;
            const language = container.dataset.language || 'en';

            // Clear any existing captcha
            container.innerHTML = "";

            // Render hCaptcha widget
            const widgetId = window.hcaptcha.render(container, {
                sitekey: sitekey,
                hl: language, // Set language for hCaptcha
                callback: (token) => {
                    // Clear the timeout since captcha was completed
                    if (this.captchaTimeout) {
                        clearTimeout(this.captchaTimeout);
                        this.captchaTimeout = null;
                    }

                    // Send token to LiveView
                    if (liveViewSocket) {
                        liveViewSocket.pushEvent("captcha_verified", { token: token });
                    }
                },
                "expired-callback": () => {
                },
                "error-callback": (error) => {
                },
            });

        },

        updated() {
            // Re-render captcha when language changes
            const container = this.el;
            const sitekey = container.dataset.sitekey;
            if (sitekey) {
                this.renderCaptcha(sitekey);
            }
        },

        destroyed() {
            // Clear timeout if component is destroyed
            if (this.captchaTimeout) {
                clearTimeout(this.captchaTimeout);
                this.captchaTimeout = null;
            }
        },
    },
};

// Add hooks to LiveSocket
const liveSocket = new LiveSocket("/live", Socket, {
    longPollFallbackMs: 2500,
    params: { _csrf_token: csrfToken },
    hooks: Hooks,
    logger: (kind, msg, data) => {
        // Disable LiveView debug logging in development
        // Logs are automatically disabled in production
    }
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// Listen for LiveView events
window.addEventListener("phx:load_existing_reports", (e) => {
    loadExistingReports(e.detail.reports);
});

window.addEventListener("phx:language_changed", (e) => {
    currentLanguage = e.detail.language || 'en';
});

window.addEventListener("phx:add_report_marker", (e) => {
    addReportMarker(
        e.detail.latitude,
        e.detail.longitude,
        e.detail.type,
        false,
        e.detail.id,
    );
});

window.addEventListener("phx:remove_report_marker", (e) => {
    removeReportMarker(e.detail.id);
});

window.addEventListener("phx:show_address_suggestions", (e) => {
    showAddressSuggestions(e.detail.suggestions);
});

window.addEventListener("phx:hide_address_suggestions", (e) => {
    hideAddressSuggestions();
});

window.addEventListener("phx:fly_to_address", (e) => {
    flyToAddress(e.detail.lat, e.detail.lng, e.detail.address);
});

window.addEventListener("phx:cleanup_completed", (e) => {
    // Refresh the map markers to ensure they're in sync
    refreshMapMarkers();
});

window.addEventListener("phx:cleanup_temporary_markers", (e) => {
    // Clean up temporary markers for a specific fingerprint
    cleanupTemporaryMarkersByFingerprint(e.detail.fingerprint);
});

window.addEventListener("phx:cleanup_all_markers_for_fingerprint", (e) => {
    // Comprehensive cleanup for both real reports and temporary markers
    cleanupAllMarkersForFingerprint(e.detail.fingerprint, e.detail.report_ids);
});

window.addEventListener("phx:refresh_browser", (e) => {
    // Refresh browser for clean state after captcha cancellation
    setTimeout(() => {
        window.location.reload();
    }, 1000); // Small delay to allow cleanup events to complete
});

// Generate browser fingerprint on page load
browserFingerprint = generateBrowserFingerprint();

// connect if there are any LiveViews on the page
liveSocket.connect();

// Set up periodic client-side cleanup every 5 minutes
setInterval(cleanupExpiredReports, 5 * 60 * 1000);

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

function initializeLeaflet() {
    const mapContainer = document.getElementById("map-container");
    if (!mapContainer) {
        return;
    }

    // Clean up existing map if it exists
    if (leafletMap) {
        leafletMap.remove();
        leafletMap = null;
        reportMarkers.clear();
        // Reset boundary layer but keep cached data for faster reload
        usBoundariesLayer = null;
    }


    // Create Leaflet map centered on USA
    leafletMap = L.map(mapContainer, {
        center: [39.8283, -98.5795], // Geographic center of USA
        zoom: 4,
        minZoom: 3,
        maxZoom: 18,
        // Optional: Restrict map bounds to US territory only
        // maxBounds: [
        //     [18.0, -180.0], // Southwest corner (includes Hawaii, Alaska)
        //     [72.0, -65.0]   // Northeast corner
        // ],
        // maxBoundsViscosity: 1.0 // Prevents dragging outside bounds
    });

    // Use CartoDB Voyager for reliable high contrast with clear roads
    L.tileLayer("https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png", {
        attribution: "© OpenStreetMap, © CartoDB",
        maxZoom: 18,
    }).addTo(leafletMap);
    
    // Alternative: Standard OpenStreetMap (has more visible borders)
    // L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
    //     attribution: "© OpenStreetMap contributors",
    //     maxZoom: 18,
    // }).addTo(leafletMap);

    // Load and display US boundaries from our database
    loadUSBoundariesLayer();

    // Allow global map bounds since we validate all 50 states server-side
    // This enables users to navigate to Alaska, Hawaii, and US territories
    // Server-side validation will reject non-US coordinates

    // Add click handler for placing reports
    leafletMap.on("click", async function(e) {
        // Validate coordinates before showing popup (now async)
        const isValid = await isValidUSCoordinate(e.latlng.lat, e.latlng.lng);
        if (isValid) {
            showReportPopup(e.latlng);
        } else {
            showCoordinateError(e.latlng);
        }
    });


    // Expose map globally
    window.leafletMap = leafletMap;

    // Set up address search functionality
    setupAddressSearch();

    // Load existing reports from DOM after map is ready
    loadExistingReportsFromDOM();

    // Watch for new reports being added to the DOM
    setupReportObserver();
}

function loadExistingReportsFromDOM() {

    // Find all report elements in the DOM
    const reportElements = document.querySelectorAll('#reports [id^="reports-"]');

    reportElements.forEach((reportElement) => {
        const lat = parseFloat(reportElement.dataset.latitude);
        const lng = parseFloat(reportElement.dataset.longitude);
        const type = reportElement.dataset.type;
        const id = reportElement.id.replace("reports-", "");

        if (lat && lng && type) {

            // Remove any temporary marker that matches this location
            removeTemporaryMarker(lat, lng, type);

            // Add the real marker
            addReportMarker(lat, lng, type, false, id);
        }
    });
}

function setupReportObserver() {
    const reportsContainer = document.getElementById('reports');
    if (!reportsContainer) return;

    const observer = new MutationObserver((mutations) => {
        mutations.forEach((mutation) => {
            mutation.addedNodes.forEach((node) => {
                if (node.nodeType === Node.ELEMENT_NODE && node.id && node.id.startsWith('reports-')) {
                    const lat = parseFloat(node.dataset.latitude);
                    const lng = parseFloat(node.dataset.longitude);
                    const type = node.dataset.type;
                    const id = node.id.replace("reports-", "");

                    if (lat && lng && type) {

                        // Remove any temporary marker that matches this location
                        removeTemporaryMarker(lat, lng, type);

                        // Add the real marker
                        addReportMarker(lat, lng, type, false, id);
                    }
                }
            });
        });
    });

    observer.observe(reportsContainer, {
        childList: true,
        subtree: true
    });

}

function setupAddressSearch() {
    const searchInput = document.getElementById("address-search");
    if (!searchInput) return;

    let selectedSuggestionIndex = -1;
    let isSearchActive = false;

    // Show overlay when input is focused
    searchInput.addEventListener("focus", function() {
        showSearchOverlay();
        isSearchActive = true;
        if (this.value.length > 0) {
            this.select(); // Select all text for easy replacement
        }
    });

    // Hide overlay when input loses focus (but only if no suggestions visible)
    searchInput.addEventListener("blur", function() {
        // Small delay to allow for clicking on suggestions
        setTimeout(() => {
            if (!document.querySelector("#address-suggestions:not(.hidden)")) {
                hideSearchOverlay();
                isSearchActive = false;
            }
        }, 150);
    });

    // Handle keyboard navigation
    searchInput.addEventListener("keydown", function(e) {
        const suggestions = document.querySelectorAll(".address-suggestion");

        if (e.key === "ArrowDown") {
            e.preventDefault();
            selectedSuggestionIndex = Math.min(selectedSuggestionIndex + 1, suggestions.length - 1);
            highlightSuggestion(suggestions, selectedSuggestionIndex);
        } else if (e.key === "ArrowUp") {
            e.preventDefault();
            selectedSuggestionIndex = Math.max(selectedSuggestionIndex - 1, -1);
            highlightSuggestion(suggestions, selectedSuggestionIndex);
        } else if (e.key === "Enter") {
            e.preventDefault();
            if (selectedSuggestionIndex >= 0 && suggestions[selectedSuggestionIndex]) {
                suggestions[selectedSuggestionIndex].click();
            } else if (suggestions.length > 0) {
                // Select first suggestion if none highlighted
                suggestions[0].click();
            }
            selectedSuggestionIndex = -1;
            hideSearchOverlay();
            isSearchActive = false;
        } else if (e.key === "Escape") {
            hideAddressSuggestions();
            hideSearchOverlay();
            selectedSuggestionIndex = -1;
            isSearchActive = false;
            searchInput.blur();
        } else {
            // Reset selection when typing
            selectedSuggestionIndex = -1;
        }
    });

    // Hide suggestions and overlay when clicking outside
    document.addEventListener("click", function(e) {
        if (
            !e.target.closest("#address-search") &&
            !e.target.closest("#address-suggestions")
        ) {
            hideAddressSuggestions();
            hideSearchOverlay();
            selectedSuggestionIndex = -1;
            isSearchActive = false;
        }
    });

    // Click on overlay to hide search
    const overlay = document.getElementById("search-overlay");
    if (overlay) {
        overlay.addEventListener("click", function() {
            hideAddressSuggestions();
            hideSearchOverlay();
            selectedSuggestionIndex = -1;
            isSearchActive = false;
            searchInput.blur();
        });
    }
}

function highlightSuggestion(suggestions, index) {
    // Remove previous highlights
    suggestions.forEach(s => s.classList.remove("bg-gradient-to-r", "from-blue-50", "to-red-50"));

    // Highlight selected suggestion
    if (index >= 0 && suggestions[index]) {
        suggestions[index].classList.add("bg-gradient-to-r", "from-blue-50", "to-red-50");
        suggestions[index].scrollIntoView({ block: "nearest" });
    }
}

function showAddressSuggestions(suggestions) {
    const suggestionsContainer = document.getElementById("address-suggestions");
    if (!suggestionsContainer) return;

    if (suggestions.length === 0) {
        hideAddressSuggestions();
        return;
    }

    const suggestionsHTML = suggestions
        .map(
            (suggestion, index) => `
        <div class="address-suggestion px-4 py-3 hover:bg-gradient-to-r hover:from-blue-50 hover:to-red-50 cursor-pointer border-b border-blue-100 last:border-b-0 transition-all duration-200"
             role="option"
             aria-selected="false"
             tabindex="-1"
             onclick="selectAddress(${suggestion.lat}, ${suggestion.lng}, '${suggestion.address.replace(/'/g, "\\'")}')">
          <div class="font-bold text-blue-700 text-sm">${suggestion.address}</div>
          <div class="text-xs text-blue-500 mt-1" aria-hidden="true">📍 Click to navigate</div>
        </div>
      `,
        )
        .join("");

    suggestionsContainer.innerHTML = `<div class="bg-white border-3 border-blue-200 rounded-xl mt-2 shadow-2xl max-h-60 overflow-y-auto">${suggestionsHTML}</div>`;
    suggestionsContainer.classList.remove("hidden");
    
    // Update ARIA attributes
    const searchInput = document.getElementById("address-search");
    if (searchInput) {
        searchInput.setAttribute("aria-expanded", "true");
    }
}

function hideAddressSuggestions() {
    const suggestionsContainer = document.getElementById("address-suggestions");
    const searchInput = document.getElementById("address-search");
    
    if (suggestionsContainer) {
        suggestionsContainer.classList.add("hidden");
        suggestionsContainer.innerHTML = "";
    }
    
    // Update ARIA attributes
    if (searchInput) {
        searchInput.setAttribute("aria-expanded", "false");
    }
}

function showSearchOverlay() {
    const overlay = document.getElementById("search-overlay");
    if (overlay) {
        overlay.classList.remove("hidden");
        overlay.classList.add("opacity-100");
    }
}

function hideSearchOverlay() {
    const overlay = document.getElementById("search-overlay");
    if (overlay) {
        overlay.classList.add("hidden");
        overlay.classList.remove("opacity-100");
    }
}

function selectAddress(lat, lng, address) {

    // Update search input with the full formatted address
    const searchInput = document.getElementById("address-search");
    if (searchInput) {
        searchInput.value = address;
        searchInput.blur(); // Remove focus to hide mobile keyboard
    }

    // Hide suggestions and overlay
    hideAddressSuggestions();
    hideSearchOverlay();

    // Send event to LiveView using the stored socket reference
    if (liveViewSocket) {
        liveViewSocket.pushEvent("select_address", {
            lat: lat,
            lng: lng,
            address: address,
        });
    }
}

function flyToAddress(lat, lng, address) {
    if (!leafletMap) return;


    // Fly to the address with a nice animation
    leafletMap.flyTo([lat, lng], 16, {
        animate: true,
        duration: 1.5,
    });

    // Add a temporary marker to show the searched location with pulse animation
    const tempMarker = L.marker([lat, lng], {
        icon: L.divIcon({
            html: `<div style="
        background: linear-gradient(135deg, #3b82f6, #ef4444); 
        border: 3px solid white; 
        border-radius: 50%; 
        width: 40px; 
        height: 40px; 
        display: flex; 
        align-items: center; 
        justify-content: center; 
        font-size: 20px;
        box-shadow: 0 4px 12px rgba(0,0,0,0.3);
        animation: pulse 2s infinite;
      ">🎯</div>
      <style>
        @keyframes pulse {
          0% { transform: scale(1); opacity: 1; }
          50% { transform: scale(1.1); opacity: 0.8; }
          100% { transform: scale(1); opacity: 1; }
        }
      </style>`,
            className: "temp-search-marker",
            iconSize: [40, 40],
            iconAnchor: [20, 20],
        }),
    }).addTo(leafletMap);

    // Add popup with address info - show full address
    tempMarker.bindPopup(`
    <div class="text-center p-3 max-w-xs">
      <div class="text-lg mb-2">🎯</div>
      <strong class="text-blue-600">Found Location</strong><br>
      <div class="text-sm text-gray-700 mt-2 leading-relaxed">${address}</div>
    </div>
  `).openPopup();

    // Remove the temporary marker after 5 seconds
    setTimeout(() => {
        if (leafletMap.hasLayer(tempMarker)) {
            leafletMap.removeLayer(tempMarker);
        }
    }, 5000);
}

function showReportPopup(latlng) {
    if (reportPopup) {
        leafletMap.closePopup(reportPopup);
    }

    // Translate popup content based on current language
    const isSpanish = currentLanguage === 'es';
    const title = isSpanish ? '🧊 Reportar Actividad' : '🧊 Report Activity';
    const checkpointText = isSpanish ? '🛑 Punto de control' : '🛑 Checkpoint';
    const operationText = isSpanish ? '🏠 Operación' : '🏠 Operation';
    const patrolText = isSpanish ? '👮 Patrulla' : '👮 Patrol';
    const facilityText = isSpanish ? '🧊 Instalación' : '🧊 Facility';

    const popupContent = `
    <div class="text-center p-2 sm:p-3" style="z-index: 9999;">
      <h3 class="text-base sm:text-lg font-black text-blue-600 mb-2 sm:mb-3">${title}</h3>
      <div class="grid grid-cols-1 gap-1.5 sm:gap-2 w-[160px] sm:w-[200px]">
        <button onclick="submitReport('${latlng.lat}', '${latlng.lng}', 'checkpoint')" 
                class="bg-white border-2 border-red-500 text-red-600 px-2 py-1.5 sm:px-4 sm:py-2 rounded-lg sm:rounded-xl font-bold hover:bg-red-50 hover:scale-105 transition-all text-xs sm:text-sm">
          ${checkpointText}
        </button>
        <button onclick="submitReport('${latlng.lat}', '${latlng.lng}', 'raid')" 
                class="bg-white border-2 border-orange-500 text-orange-600 px-2 py-1.5 sm:px-4 sm:py-2 rounded-lg sm:rounded-xl font-bold hover:bg-orange-50 hover:scale-105 transition-all text-xs sm:text-sm">
          ${operationText}
        </button>
        <button onclick="submitReport('${latlng.lat}', '${latlng.lng}', 'patrol')" 
                class="bg-white border-2 border-blue-500 text-blue-600 px-2 py-1.5 sm:px-4 sm:py-2 rounded-lg sm:rounded-xl font-bold hover:bg-blue-50 hover:scale-105 transition-all text-xs sm:text-sm">
          ${patrolText}
        </button>
        <button onclick="submitReport('${latlng.lat}', '${latlng.lng}', 'detention')" 
                class="bg-white border-2 border-purple-500 text-purple-600 px-2 py-1.5 sm:px-4 sm:py-2 rounded-lg sm:rounded-xl font-bold hover:bg-purple-50 hover:scale-105 transition-all text-xs sm:text-sm">
          ${facilityText}
        </button>
      </div>
    </div>
  `;

    reportPopup = L.popup({
        maxWidth: 300,
        className: "custom-popup",
    })
        .setLatLng(latlng)
        .setContent(popupContent)
        .openOn(leafletMap);
}

// Function to submit report via LiveView
window.submitReport = function(lat, lng, type) {

    // Close the popup
    if (reportPopup) {
        leafletMap.closePopup(reportPopup);
    }

    // Send event to LiveView using the stored socket reference
    if (liveViewSocket) {
        liveViewSocket.pushEvent("map_report", {
            latitude: parseFloat(lat),
            longitude: parseFloat(lng),
            type: type,
            fingerprint: browserFingerprint
        });
    } else {
    }

    // Add temporary marker immediately for instant feedback
    const tempMarker = addReportMarker(lat, lng, type, true);

    // Track this temporary marker by fingerprint so we can remove it if captcha is cancelled
    if (tempMarker && browserFingerprint) {
        if (!temporaryMarkersByFingerprint.has(browserFingerprint)) {
            temporaryMarkersByFingerprint.set(browserFingerprint, []);
        }
        temporaryMarkersByFingerprint.get(browserFingerprint).push(tempMarker);
    }
};

// Make selectAddress globally available
window.selectAddress = selectAddress;

// Browser fingerprinting for better rate limiting
function generateBrowserFingerprint() {
    const canvas = document.createElement('canvas');
    const ctx = canvas.getContext('2d');
    ctx.textBaseline = 'top';
    ctx.font = '14px Arial';
    ctx.fillText('Browser fingerprint', 2, 2);

    const fingerprint = {
        screen: `${screen.width}x${screen.height}x${screen.colorDepth}`,
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        language: navigator.language,
        languages: navigator.languages ? navigator.languages.join(',') : '',
        platform: navigator.platform,
        userAgent: navigator.userAgent,
        cookieEnabled: navigator.cookieEnabled,
        doNotTrack: navigator.doNotTrack || 'unspecified',
        hardwareConcurrency: navigator.hardwareConcurrency || 0,
        deviceMemory: navigator.deviceMemory || 0,
        canvas: canvas.toDataURL(),
        touchSupport: 'ontouchstart' in window,
        webgl: getWebGLFingerprint()
    };

    // Create hash of the fingerprint
    const fpString = Object.values(fingerprint).join('|');
    return hashString(fpString);
}

function getWebGLFingerprint() {
    try {
        const canvas = document.createElement('canvas');
        const gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
        if (!gl) return 'no-webgl';

        const vendor = gl.getParameter(gl.VENDOR);
        const renderer = gl.getParameter(gl.RENDERER);
        return `${vendor}~${renderer}`;
    } catch (e) {
        return 'webgl-error';
    }
}

function hashString(str) {
    let hash = 0;
    if (str.length === 0) return hash.toString();
    for (let i = 0; i < str.length; i++) {
        const char = str.charCodeAt(i);
        hash = ((hash << 5) - hash) + char;
        hash = hash & hash; // Convert to 32-bit integer
    }
    return Math.abs(hash).toString(36);
}

// Function to add report markers with emojis
function addReportMarker(lat, lng, type, isTemporary = false, reportId = null) {
    if (!leafletMap) return;

    // Check if this report ID has been removed - don't re-add it
    if (reportId && removedReportIds.has(String(reportId))) {
        return null;
    }

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
      transition: transform 0.2s;
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

    // Store marker if it has a report ID
    if (reportId) {
        // Check if there's already a temporary marker at this location that we should convert
        const matchingTempIndex = temporaryMarkers.findIndex(temp =>
            Math.abs(temp.lat - lat) < 0.001 &&
            Math.abs(temp.lng - lng) < 0.001 &&
            temp.type === type
        );

        if (matchingTempIndex !== -1) {
            // Convert existing temporary marker to permanent
            const tempMarker = temporaryMarkers[matchingTempIndex];

            // Update the marker icon to use permanent color
            const permanentColor = getColorForType(type);
            const updatedIcon = L.divIcon({
                html: `<div style="
          background: ${permanentColor}; 
          border: 3px solid white; 
          border-radius: 50%; 
          width: 40px; 
          height: 40px; 
          display: flex; 
          align-items: center; 
          justify-content: center; 
          font-size: 20px;
          box-shadow: 0 4px 12px rgba(0,0,0,0.3);
          transition: transform 0.2s;
        ">${emoji}</div>`,
                className: "custom-emoji-marker",
                iconSize: [40, 40],
                iconAnchor: [20, 20],
            });

            tempMarker.marker.setIcon(updatedIcon);

            // Update the popup to show "Reported" instead of "Submitting..."
            tempMarker.marker.setPopupContent(`
        <div class="text-center">
          <strong>${emoji} ${getTypeDisplayName(type)}</strong><br>
          <small class="text-gray-600">Reported</small>
        </div>
      `);

            // Store the existing marker with the report ID
            reportMarkers.set(reportId, tempMarker.marker);

            // Remove from temporary tracking
            temporaryMarkers.splice(matchingTempIndex, 1);

            return tempMarker.marker;
        } else {
            // No matching temporary marker, store this new marker
            reportMarkers.set(reportId, marker);
        }
    } else if (isTemporary) {
        // Track temporary markers so we can remove them later
        temporaryMarkers.push({
            marker: marker,
            lat: lat,
            lng: lng,
            type: type,
            reportId: reportId // Store reportId even for temporary markers
        });
    }

    return marker;
}

// Function to remove report marker
function removeReportMarker(reportId) {
    if (!leafletMap) return;

    // Add to removed IDs list to prevent re-adding
    removedReportIds.add(String(reportId));

    // Remove from tracked markers
    if (reportMarkers.has(reportId)) {
        const marker = reportMarkers.get(reportId);
        leafletMap.removeLayer(marker);
        reportMarkers.delete(reportId);
    }

    // Also check for any temporary markers that might have this ID
    // (in case a temporary marker was created but not properly replaced)
    const initialTempCount = temporaryMarkers.length;
    temporaryMarkers = temporaryMarkers.filter(temp => {
        if (temp.reportId === reportId) {
            leafletMap.removeLayer(temp.marker);
            return false; // Remove from array
        }
        return true; // Keep in array
    });

    // Force refresh of map markers to ensure consistency
    if (initialTempCount > temporaryMarkers.length || reportMarkers.has(reportId)) {
        setTimeout(() => {
            refreshMapMarkers();
        }, 100);
    }
}

// Function to remove temporary markers that match the real report
function removeTemporaryMarker(lat, lng, type) {
    const threshold = 0.0001; // Small threshold for coordinate matching

    for (let i = temporaryMarkers.length - 1; i >= 0; i--) {
        const temp = temporaryMarkers[i];
        if (
            Math.abs(temp.lat - lat) < threshold &&
            Math.abs(temp.lng - lng) < threshold &&
            temp.type === type
        ) {
            leafletMap.removeLayer(temp.marker);
            temporaryMarkers.splice(i, 1);
            break; // Only remove the first match
        }
    }
}

// Function to clean up all temporary markers for a specific fingerprint
function cleanupTemporaryMarkersByFingerprint(fingerprint) {
    if (!leafletMap) return;


    const markersToCleanup = temporaryMarkersByFingerprint.get(fingerprint);
    if (markersToCleanup) {
        markersToCleanup.forEach(marker => {
            if (leafletMap.hasLayer(marker)) {
                leafletMap.removeLayer(marker);
            }
        });

        // Remove from tracking
        temporaryMarkersByFingerprint.delete(fingerprint);

        // Also clean up from the general temporaryMarkers array
        temporaryMarkers = temporaryMarkers.filter(temp => {
            if (markersToCleanup.includes(temp.marker)) {
                return false;
            }
            return true;
        });
    }
}

// Function to clean up ALL markers (both real and temporary) for a specific fingerprint
function cleanupAllMarkersForFingerprint(fingerprint, reportIds) {
    if (!leafletMap) return;


    // First, clean up any temporary markers for this specific fingerprint
    cleanupTemporaryMarkersByFingerprint(fingerprint);

    // Then clean up real report markers by their specific IDs
    if (reportIds && reportIds.length > 0) {
        reportIds.forEach(reportId => {
            const stringId = String(reportId);
            const intId = parseInt(reportId);

            // Add to removed IDs list to prevent re-adding
            removedReportIds.add(stringId);

            // Remove from our tracking - try all possible ID formats
            [reportId, stringId, intId].forEach(id => {
                if (reportMarkers.has(id)) {
                    const marker = reportMarkers.get(id);
                    if (leafletMap.hasLayer(marker)) {
                        leafletMap.removeLayer(marker);
                    }
                    reportMarkers.delete(id);
                }
            });

            // Also remove the DOM element to prevent it from being reloaded
            const domElement = document.getElementById(`reports-${stringId}`);
            if (domElement) {
                domElement.remove();
            }
        });
    }

    // Additional safety: scan for any markers that might match the report IDs but weren't properly tracked
    const reportIdSet = new Set(reportIds ? reportIds.map(id => String(id)) : []);

    leafletMap.eachLayer(layer => {
        if (layer instanceof L.Marker && layer.options.icon && layer.options.icon.options.className === "custom-emoji-marker") {
            // Check if this marker might correspond to one of the report IDs we're cleaning up
            // This is safe because we only remove markers for the specific report IDs from this user
            let markerReportId = null;

            // Try to find the report ID associated with this marker
            for (const [id, trackedMarker] of reportMarkers.entries()) {
                if (trackedMarker === layer) {
                    markerReportId = String(id);
                    break;
                }
            }

            // Only remove if this marker matches one of the report IDs we're supposed to clean up
            if (markerReportId && reportIdSet.has(markerReportId)) {
                leafletMap.removeLayer(layer);
            }
        }
    });

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
function loadExistingReports(reports) {
    if (!leafletMap) return;

    reports.forEach((report) => {
        addReportMarker(
            report.latitude,
            report.longitude,
            report.type,
            false,
            report.id,
        );
    });
}

// Function to refresh map markers based on current DOM state
function refreshMapMarkers() {
    if (!leafletMap) return;


    // Clear all existing markers
    reportMarkers.forEach((marker, reportId) => {
        leafletMap.removeLayer(marker);
    });
    reportMarkers.clear();

    // DON'T clear temporary markers - let them be converted naturally
    // temporaryMarkers should persist until converted to permanent markers

    // Reload markers from current DOM state
    loadExistingReportsFromDOM();
}

// Function to periodically check for expired reports on client-side
function cleanupExpiredReports() {
    if (!leafletMap) return;

    const now = new Date();
    const expiredIds = [];

    // Check DOM elements for expired reports (4 hours = 4 * 60 * 60 * 1000 ms)
    const reportElements = document.querySelectorAll('#reports [id^="reports-"]');

    reportElements.forEach(element => {
        const insertedAt = element.dataset.insertedAt;
        if (insertedAt) {
            const insertedTime = new Date(insertedAt);
            const expiresAt = new Date(insertedTime.getTime() + 4 * 60 * 60 * 1000);

            if (now > expiresAt) {
                const reportId = element.id.replace("reports-", "");
                expiredIds.push(reportId);

                // Remove the DOM element
                element.remove();

                // Remove marker from map
                removeReportMarker(reportId);
            }
        }
    });

    if (expiredIds.length > 0) {
    }
}


// No tooltip JavaScript needed - using static explanatory text instead

// Add mobile-specific event listeners
document.addEventListener('DOMContentLoaded', function() {
    // Improve mobile scrolling
    document.body.style.webkitOverflowScrolling = 'touch';

    // Handle mobile orientation changes
    window.addEventListener('orientationchange', function() {
        // Delay to allow for orientation change completion
        setTimeout(() => {
            if (leafletMap) {
                leafletMap.invalidateSize();
            }
        }, 500);
    });

    // Handle mobile keyboard visibility
    const addressInput = document.getElementById('address-search');
    if (addressInput && /Mobi|Android/i.test(navigator.userAgent)) {
        addressInput.addEventListener('focus', function() {
            // On mobile, scroll to input when keyboard appears
            setTimeout(() => {
                this.scrollIntoView({ behavior: 'smooth', block: 'center' });
            }, 300);
        });
    }
});

// Add CSS for popup z-index and search overlay
const style = document.createElement("style");
style.textContent = `
  .custom-popup .leaflet-popup-content-wrapper {
    z-index: 9999 !important;
  }
  .leaflet-popup {
    z-index: 9999 !important;
  }
  
  /* Ensure address search components have proper z-index */
  #address-search {
    position: relative;
    z-index: 10000 !important;
  }
  
  #address-suggestions {
    z-index: 10001 !important;
  }
  
  #search-overlay {
    z-index: 9998 !important;
  }
  
  /* Smooth transitions for overlay */
  #search-overlay {
    opacity: 0;
    transition: opacity 0.3s ease-in-out;
  }
  
  #search-overlay:not(.hidden) {
    opacity: 1;
  }
  
  /* No tooltip styles needed - using static explanatory text instead */
  
  /* Touch-friendly button styling */
  .touch-manipulation {
    touch-action: manipulation;
  }
  
  /* Mobile-specific improvements */
  @media (max-width: 768px) {
    /* Improve touch targets */
    button, .cursor-pointer {
      min-height: 44px;
      min-width: 44px;
    }
    
    /* Better mobile typography */
    body {
      -webkit-text-size-adjust: 100%;
      -webkit-font-smoothing: antialiased;
    }
    
    /* Improve mobile scrolling */
    * {
      -webkit-overflow-scrolling: touch;
    }
    
    /* Mobile-friendly map popup */
    .leaflet-popup-content {
      margin: 8px 12px;
      line-height: 1.4;
    }
    
    .leaflet-popup-content-wrapper {
      border-radius: 12px;
    }
    
    /* Address suggestion focus styles */
    .address-suggestion.focused {
      background-color: #3b82f6 !important;
      color: white !important;
    }
  }
`;
document.head.appendChild(style);

// ===== ACCESSIBILITY FUNCTIONS =====

// Focus management variables
let lastFocusedElement = null;
let focusableElements = [];
let currentFocusIndex = 0;

// Screen reader announcement function
function announceToScreenReader(message, urgent = false) {
    const container = urgent ? document.getElementById('sr-urgent') : document.getElementById('sr-announcements');
    if (container) {
        // Clear previous announcement
        container.textContent = '';
        
        // Add new announcement with slight delay to ensure screen readers pick it up
        setTimeout(() => {
            container.textContent = message;
        }, 100);
        
        // Clear after announcement to avoid repetition
        setTimeout(() => {
            container.textContent = '';
        }, 3000);
    }
}

// Focus trap for modals
function trapFocus(modalElement) {
    if (!modalElement) return;
    
    focusableElements = modalElement.querySelectorAll(
        'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
    );
    
    if (focusableElements.length === 0) return;
    
    const firstElement = focusableElements[0];
    const lastElement = focusableElements[focusableElements.length - 1];
    
    // Focus first element
    firstElement.focus();
    
    // Add event listener for tab trapping
    const trapTabKey = (e) => {
        if (e.key === 'Tab') {
            if (e.shiftKey) {
                // Shift + Tab
                if (document.activeElement === firstElement) {
                    e.preventDefault();
                    lastElement.focus();
                }
            } else {
                // Tab
                if (document.activeElement === lastElement) {
                    e.preventDefault();
                    firstElement.focus();
                }
            }
        }
        
        if (e.key === 'Escape') {
            e.preventDefault();
            closeModal();
        }
    };
    
    modalElement.addEventListener('keydown', trapTabKey);
    
    // Store cleanup function
    modalElement._cleanupFocusTrap = () => {
        modalElement.removeEventListener('keydown', trapTabKey);
    };
}

// Close modal and restore focus
function closeModal() {
    const modal = document.getElementById('captcha-modal');
    if (modal && modal._cleanupFocusTrap) {
        modal._cleanupFocusTrap();
    }
    
    // Restore focus to previously focused element
    if (lastFocusedElement) {
        lastFocusedElement.focus();
        lastFocusedElement = null;
    }
    
    // Trigger Phoenix event to close modal
    if (window.liveSocket) {
        window.liveSocket.execJS(document.body, "phx-click=\"cancel_captcha\"");
    }
}

// Store focus before opening modal
function storeFocusBeforeModal() {
    lastFocusedElement = document.activeElement;
}

// Event listeners for modal management
window.addEventListener('phx:captcha_shown', () => {
    storeFocusBeforeModal();
    
    // Wait for modal to be fully rendered
    setTimeout(() => {
        const modal = document.getElementById('captcha-modal');
        if (modal) {
            trapFocus(modal);
            announceToScreenReader('Security verification dialog opened. Please complete the captcha to continue.', true);
        }
    }, 100);
});

window.addEventListener('phx:captcha_hidden', () => {
    if (lastFocusedElement) {
        lastFocusedElement.focus();
        lastFocusedElement = null;
    }
});

// Add keyboard navigation for address suggestions
function addAddressKeyboardNavigation() {
    const addressInput = document.getElementById('address-search');
    if (!addressInput) return;
    
    let currentIndex = -1;
    
    addressInput.addEventListener('keydown', (e) => {
        const suggestions = document.querySelectorAll('.address-suggestion');
        if (suggestions.length === 0) return;
        
        switch (e.key) {
            case 'ArrowDown':
                e.preventDefault();
                currentIndex = Math.min(currentIndex + 1, suggestions.length - 1);
                updateSuggestionFocus(suggestions, currentIndex);
                break;
                
            case 'ArrowUp':
                e.preventDefault();
                currentIndex = Math.max(currentIndex - 1, -1);
                if (currentIndex === -1) {
                    addressInput.focus();
                    clearSuggestionFocus(suggestions);
                } else {
                    updateSuggestionFocus(suggestions, currentIndex);
                }
                break;
                
            case 'Enter':
                if (currentIndex >= 0 && suggestions[currentIndex]) {
                    e.preventDefault();
                    suggestions[currentIndex].click();
                }
                break;
                
            case 'Escape':
                e.preventDefault();
                hideSuggestions();
                currentIndex = -1;
                break;
        }
    });
    
    // Reset index when suggestions change
    window.addEventListener('phx:address_suggestions_updated', () => {
        currentIndex = -1;
    });
}

function updateSuggestionFocus(suggestions, index) {
    clearSuggestionFocus(suggestions);
    if (suggestions[index]) {
        suggestions[index].classList.add('focused');
        suggestions[index].setAttribute('aria-selected', 'true');
        suggestions[index].focus();
    }
}

function clearSuggestionFocus(suggestions) {
    suggestions.forEach(suggestion => {
        suggestion.classList.remove('focused');
        suggestion.setAttribute('aria-selected', 'false');
    });
}

function hideSuggestions() {
    const suggestionsContainer = document.getElementById('address-suggestions');
    if (suggestionsContainer) {
        suggestionsContainer.classList.add('hidden');
        suggestionsContainer.setAttribute('aria-expanded', 'false');
    }
}

// Initialize keyboard navigation when page loads
document.addEventListener('DOMContentLoaded', addAddressKeyboardNavigation);

// Announce new reports to screen readers
window.addEventListener('phx:new_report_added', (e) => {
    if (e.detail && e.detail.type && e.detail.location) {
        const reportType = e.detail.type;
        const location = e.detail.location;
        const message = `New ${reportType} report added at ${location}`;
        announceToScreenReader(message);
    }
});

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

