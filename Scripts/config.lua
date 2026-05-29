local Config = {
    -- Key to open/close the large map (UE4SS key names: "M", "TAB", "F6", etc.) https://docs.ue4ss.com/lua-api/table-definitions/key.html
    OpenMapKey = "M",
    -- Modifier keys for the open map key (e.g. {"SHIFT"}, {"CONTROL"})
    OpenMapModifiers = {},

    -- Key to show/hide the minimap
    HideMapKey = "H",
    -- Modifier keys for the hide map key
    HideMapModifiers = {},

    -- Zoom in / out keys. They affect whichever map is currently shown
    -- (minimap or the large map). Key names: see the UE4SS Key table linked above.
    ZoomInKey = "ADD",          -- numpad +
    ZoomInModifiers = {},
    ZoomOutKey = "SUBTRACT",     -- numpad -
    ZoomOutModifiers = {},

    -- Large-map pan keys (arrow keys). Active only while the large map is open
    -- and zoomed past 1.0. Key names: see the UE4SS Key table linked above.
    PanUpKey = "UP_ARROW",
    PanUpModifiers = {},
    PanDownKey = "DOWN_ARROW",
    PanDownModifiers = {},
    PanLeftKey = "LEFT_ARROW",
    PanLeftModifiers = {},
    PanRightKey = "RIGHT_ARROW",
    PanRightModifiers = {},

    -- If true, the minimap is visible when the game starts
    ShowMinimapAtStartup = true,
    -- Default map refresh interval (milliseconds)
    UpdateIntervalMs = 500,
    -- Delay before the first attempt to attach the overlay to the HUD (ms)
    AttachInitialDelayMs = 250,
    -- Successive retry delays if the overlay fails to attach (ms)
    AttachRetryDelaysMs = { 250, 500, 1000, 2000, 5000 },
    -- How often the game window size is polled for changes (ms)
    ViewportPollIntervalMs = 1000,
    -- Key debounce time to prevent double presses (ms)
    KeyDebounceMs = 600,

    Map = {
        ImageFile = "mapgenie_SN2_world_HIRES.png.lua",
        -- DO NOT CHANGE! THIS IS THE RESOLUTION OF THE IMAGE ITSELF
        ImageWidth = 9145,
        -- DO NOT CHANGE! THIS IS THE RESOLUTION OF THE IMAGE ITSELF
        ImageHeight = 3845,
        ProjectionMode = "MapGenie",
        LngFromXScale = 0.0000028912681189998626,
        LngFromXOffset = -0.049961343800042045,
        LatFromYScale = -0.000002992336954998909,
        LatFromYOffset = 2.0063350541995395,
        BoundsWest = -1.13,
        BoundsEast = -0.345,
        BoundsSouth = 0.565,
        BoundsNorth = 0.895,
        HorizontalAxis = "X",
        VerticalAxis = "Y",
        WorldMinX = -70000.0,
        WorldMaxX = 70000.0,
        WorldMinY = -70000.0,
        WorldMaxY = 70000.0,
        AutoCenterOnFirstPlayerPosition = false,
        AutoCenterSpanX = 140000.0,
        AutoCenterSpanY = 140000.0,
        InitialMapU = 0.5,
        InitialMapV = 0.5,
        InvertVertical = true,
        ClampMarkerToMap = true,
    },

    Minimap = {
        -- Enables or disables the minimap
        Enabled = true,
        -- Minimap refresh interval (ms)
        UpdateIntervalMs = 500,
        -- Screen anchor for the minimap ("TopRight", "TopLeft", "BottomRight", "BottomLeft", "Center")
        Anchor = "TopRight",
        -- Fixed minimap width in pixels (height adapts to the image aspect ratio)
        Width = 360,
        -- Zoom factor: 1.0 = whole map fits the box; higher = magnified + follows you.
        Zoom = 3.0,
        ZoomMin = 1.0,
        ZoomMax = 12.0,
        -- Amount added (zoom in) / removed (zoom out) per keypress. Use 1, 0.5, 0.25, etc.
        ZoomStep = 0.5,
        -- Margin from the top of the screen (pixels)
        MarginTop = 24,
        -- Margin from the right of the screen (pixels)
        MarginRight = 24,
        -- Opacity of the dark background behind the minimap (0.0 = transparent, 1.0 = opaque)
        BackgroundAlpha = 0.55,
        -- Opacity of the map image itself
        MapAlpha = 0.92,
        -- Border thickness around the minimap (pixels)
        BorderThickness = 2,
    },

    LargeMap = {
        -- Large map refresh interval (ms, faster since it's the main focus)
        UpdateIntervalMs = 200,
        -- Screen anchor for the large map (centered)
        Anchor = "Center",
        -- Large map width as a fraction of the screen (0.90 = 90%)
        WidthRatio = 0.90,
        -- Large map height as a fraction of the screen (0.72 = 72%)
        HeightRatio = 0.72,
        -- Zoom factor: 1.0 = whole map fits the box; higher = magnified + follows you.
        Zoom = 1.0,
        ZoomMin = 1.0,
        ZoomMax = 8.0,
        -- Amount added (zoom in) / removed (zoom out) per keypress. Use 1, 0.5, 0.25, etc.
        ZoomStep = 0.5,
        -- Pan distance per arrow press, as a fraction of the visible view
        -- (only applies once zoomed past 1.0). Arrow keys by default.
        PanStep = 0.25,
        -- Opacity of the dark background behind the large map
        BackgroundAlpha = 0.88,
        -- Opacity of the map image
        MapAlpha = 1.0,
        -- Border thickness (pixels)
        BorderThickness = 3,
        -- If true, dims the entire screen behind the large map
        DimBackground = true,
    },

    Marker = {
        -- Player marker image file (directional arrow)
        ImageFile = "MapArrowRight.png.lua",
        -- Marker size in pixels
        Size = 12,
        -- Pixel movement threshold before redrawing the marker (avoids micro-updates)
        MoveThresholdPixels = 4,
        -- Rotation threshold in degrees before redrawing the marker heading
        HeadingThresholdDegrees = 3,
        -- Movement threshold in UE units before the player is considered to have moved
        WorldMoveThreshold = 150.0,
        -- Marker color (R, G, B, A — cyan here)
        Color = { R = 0.0, G = 0.9, B = 1.0, A = 1.0 },
    },

    FogOfWar = {
        -- Enables or disables fog of war
        Enabled = true,
        -- Number of horizontal cells in the fog grid
        GridWidth = 57,
        -- Number of vertical cells in the fog grid
        GridHeight = 24,
        -- Reveal radius around the player (in cells)
        RevealRadius = 2,
        -- Save file for fog state (which cells have been revealed)
        SaveFile = "fog_state.dat",
        -- Opacity of unrevealed fog (0.0 = invisible, 1.0 = fully opaque)
        FogAlpha = 0.95,
        -- Throttle for the on-screen fog refresh (ms): newly-revealed cells are
        -- batched and redrawn at most this often, keeping disk + texture work
        -- off the travel hot path. Fog may appear up to this late (unnoticeable).
        VisualThrottleMs = 750,
        -- Throttle for writing fog progress to disk (ms). Also force-saved on map
        -- change. Worst-case loss on a hard crash = reveals within this window.
        SaveThrottleMs = 20000,
    },

    Debug = {
        LogPosition = false,
        DrawCoordinates = false,
    },
}

return Config
