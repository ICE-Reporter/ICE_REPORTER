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

// LiveView hook for map initialization
const Hooks = {
    MapContainer: {
        mounted() {
            liveViewSocket = this; // Store reference to the LiveView
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
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// Listen for LiveView events
window.addEventListener("phx:load_existing_reports", (e) => {
    loadExistingReports(e.detail.reports);
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
    }


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
    leafletMap.on("click", function(e) {
        showReportPopup(e.latlng);
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
            (suggestion) => `
        <div class="address-suggestion px-4 py-3 hover:bg-gradient-to-r hover:from-blue-50 hover:to-red-50 cursor-pointer border-b border-blue-100 last:border-b-0 transition-all duration-200"
             onclick="selectAddress(${suggestion.lat}, ${suggestion.lng}, '${suggestion.address.replace(/'/g, "\\'")}')">
          <div class="font-bold text-blue-700 text-sm">${suggestion.address}</div>
          <div class="text-xs text-blue-500 mt-1">📍 Click to navigate</div>
        </div>
      `,
        )
        .join("");

    suggestionsContainer.innerHTML = `<div class="bg-white border-3 border-blue-200 rounded-xl mt-2 shadow-2xl max-h-60 overflow-y-auto">${suggestionsHTML}</div>`;
    suggestionsContainer.classList.remove("hidden");
}

function hideAddressSuggestions() {
    const suggestionsContainer = document.getElementById("address-suggestions");
    if (suggestionsContainer) {
        suggestionsContainer.classList.add("hidden");
        suggestionsContainer.innerHTML = "";
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

    const popupContent = `
    <div class="text-center p-2 sm:p-3" style="z-index: 9999;">
      <h3 class="text-base sm:text-lg font-black text-blue-600 mb-2 sm:mb-3">🧊 Report Activity</h3>
      <div class="grid grid-cols-1 gap-1.5 sm:gap-2 w-[160px] sm:w-[200px]">
        <button onclick="submitReport('${latlng.lat}', '${latlng.lng}', 'checkpoint')" 
                class="bg-white border-2 border-red-500 text-red-600 px-2 py-1.5 sm:px-4 sm:py-2 rounded-lg sm:rounded-xl font-bold hover:bg-red-50 hover:scale-105 transition-all text-xs sm:text-sm">
          🛑 Checkpoint
        </button>
        <button onclick="submitReport('${latlng.lat}', '${latlng.lng}', 'raid')" 
                class="bg-white border-2 border-orange-500 text-orange-600 px-2 py-1.5 sm:px-4 sm:py-2 rounded-lg sm:rounded-xl font-bold hover:bg-orange-50 hover:scale-105 transition-all text-xs sm:text-sm">
          🏠 Operation
        </button>
        <button onclick="submitReport('${latlng.lat}', '${latlng.lng}', 'patrol')" 
                class="bg-white border-2 border-blue-500 text-blue-600 px-2 py-1.5 sm:px-4 sm:py-2 rounded-lg sm:rounded-xl font-bold hover:bg-blue-50 hover:scale-105 transition-all text-xs sm:text-sm">
          👮 Patrol
        </button>
        <button onclick="submitReport('${latlng.lat}', '${latlng.lng}', 'detention')" 
                class="bg-white border-2 border-purple-500 text-purple-600 px-2 py-1.5 sm:px-4 sm:py-2 rounded-lg sm:rounded-xl font-bold hover:bg-purple-50 hover:scale-105 transition-all text-xs sm:text-sm">
          🧊 Facility
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
  }
`;
document.head.appendChild(style);

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

