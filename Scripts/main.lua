local UEHelpers = require("UEHelpers")
local Config = require("config")

local MOD_NAME = "SubnauticaMapMod"
local VISIBLE = 3 -- ESlateVisibility::HitTestInvisible
local HIDDEN = 2  -- ESlateVisibility::Hidden
local DEFAULT_ATTACH_RETRY_DELAYS_MS = { 250, 500, 1000, 2000, 5000 }

local mapVisible = Config.ShowMinimapAtStartup ~= false
local largeMapOpen = false
local minimapZoom = (Config.Minimap and Config.Minimap.Zoom) or 1.0
local largeMapZoom = (Config.LargeMap and Config.LargeMap.Zoom) or 1.0
local largeMapViewU = nil
local largeMapViewV = nil
local textureLoadAttempted = false
local pixelLoadAttempted = false
local arrowLoadAttempted = false
local attachAttemptQueued = false
local attachAttemptToken = 0
local attachRetryIndex = 1
local updateLoopActive = false
local updateLoopToken = 0
local attachAttemptLogged = false
local overlayAttachedLogged = false
local updateErrorLogged = false
local openToggleLocked = false
local hideToggleLocked = false
local calibrationLogged = false
local sampleQueued = false
local overlayGeneration = 0
local frameSample = {}
local drawState = {}
local mapPoint = {}
local cachedScreenW = 1920
local cachedScreenH = 1080
local viewportDirty = true
local viewportPollCountdown = 0

local fogGrid = {}
local fogDirty = false
local fogLastCellX = nil
local fogLastCellY = nil
local fogSaveDirty = false
local fogFlushPending = false
local fogSavePending = false
local isFogEnabled
local loadFogTexture
local scheduleFogFlush
local flushFogVisual
local scheduleFogSave
local flushFogSave

local renderingLibrary = CreateInvalidObject()
local widgetLayoutLibrary = CreateInvalidObject()
local mapTexture = CreateInvalidObject()
local pixelTexture = CreateInvalidObject()
local arrowTexture = CreateInvalidObject()
local fogTexture = CreateInvalidObject()

local overlay = {
    hudScreen = CreateInvalidObject(),
    root = CreateInvalidObject(),
    canvas = CreateInvalidObject(),
    canvasSlot = nil,
    viewport = CreateInvalidObject(),
    viewportSlot = nil,
    dim = CreateInvalidObject(),
    dimSlot = nil,
    map = CreateInvalidObject(),
    mapSlot = nil,
    borderTop = CreateInvalidObject(),
    borderTopSlot = nil,
    borderRight = CreateInvalidObject(),
    borderRightSlot = nil,
    borderBottom = CreateInvalidObject(),
    borderBottomSlot = nil,
    borderLeft = CreateInvalidObject(),
    borderLeftSlot = nil,
    marker = CreateInvalidObject(),
    markerSlot = nil,
    mapTextureApplied = false,
    markerTextureApplied = false,
    fog = CreateInvalidObject(),
    fogSlot = nil,
    fogTextureApplied = false,
    lastCanvasVisible = nil,
    lastDimVisible = nil,
    lastMarkerVisible = nil,
    lastMarkerXKey = nil,
    lastMarkerYKey = nil,
    lastMarkerAngleKey = nil,
    lastMarkerSize = nil,
    lastHeadingAngleKey = nil,
}

local widgetClasses = {}
local runtimeBounds = nil
local configuredBounds = {
    MinX = Config.Map.WorldMinX,
    MaxX = Config.Map.WorldMaxX,
    MinY = Config.Map.WorldMinY,
    MaxY = Config.Map.WorldMaxY,
}
local mapGenieProjection = nil

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, message))
end

local function isValid(object)
    return object and object.IsValid and object:IsValid()
end

local scratchVec2 = { X = 0.0, Y = 0.0 }
local function vec2(x, y)
    scratchVec2.X = x
    scratchVec2.Y = y
    return scratchVec2
end

local function color(value, fallbackAlpha)
    value = value or {}
    return {
        R = value.R or 1.0,
        G = value.G or 1.0,
        B = value.B or 1.0,
        A = value.A or fallbackAlpha or 1.0,
    }
end

local COLOR_BLACK = { R = 0.0, G = 0.0, B = 0.0, A = 0.45 }
local COLOR_WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
local COLOR_BORDER = { R = 0.0, G = 0.8, B = 1.0, A = 0.85 }
local COLOR_MARKER = color((Config.Marker or {}).Color, 1.0)

local lastWorldX = nil
local lastWorldY = nil
local lastForwardX = nil
local lastForwardY = nil

local cachedPawn = CreateInvalidObject()
local pawnCheckCountdown = 0
local PAWN_CHECK_INTERVAL = 10

local function clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function quantize(value, step)
    step = step or 1
    if step <= 0 then return value end
    return math.floor((value / step) + 0.5)
end

local function safeCall(label, fn)
    local ok, result = pcall(fn)
    if not ok then
        log(label .. " failed: " .. tostring(result))
        return nil
    end
    return result
end

local function resetOverlayCaches()
    overlay.lastLayoutLarge = nil
    overlay.lastLayoutScreenW = nil
    overlay.lastLayoutScreenH = nil
    overlay.lastLayoutXKey = nil
    overlay.lastLayoutYKey = nil
    overlay.lastLayoutWidthKey = nil
    overlay.lastLayoutHeightKey = nil
    overlay.lastLayoutMapAlpha = nil
    overlay.lastLayoutBackgroundAlpha = nil
    overlay.lastLayoutBorderThickness = nil
    overlay.lastLayoutDimVisible = nil
    overlay.lastCanvasVisible = nil
    overlay.lastDimVisible = nil
    overlay.lastMarkerVisible = nil
    overlay.lastMarkerXKey = nil
    overlay.lastMarkerYKey = nil
    overlay.lastMarkerAngleKey = nil
    overlay.lastMarkerSize = nil
    overlay.lastHeadingAngleKey = nil
end

local function clearOverlayWidgetRefs(clearOwner)
    if clearOwner then
        overlay.hudScreen = CreateInvalidObject()
        overlay.root = CreateInvalidObject()
    end

    overlay.canvas = CreateInvalidObject()
    overlay.canvasSlot = nil
    overlay.viewport = CreateInvalidObject()
    overlay.viewportSlot = nil
    overlay.dim = CreateInvalidObject()
    overlay.dimSlot = nil
    overlay.map = CreateInvalidObject()
    overlay.mapSlot = nil
    overlay.borderTop = CreateInvalidObject()
    overlay.borderTopSlot = nil
    overlay.borderRight = CreateInvalidObject()
    overlay.borderRightSlot = nil
    overlay.borderBottom = CreateInvalidObject()
    overlay.borderBottomSlot = nil
    overlay.borderLeft = CreateInvalidObject()
    overlay.borderLeftSlot = nil
    overlay.marker = CreateInvalidObject()
    overlay.markerSlot = nil
    overlay.mapTextureApplied = false
    overlay.markerTextureApplied = false
    overlay.fog = CreateInvalidObject()
    overlay.fogSlot = nil
    overlay.fogTextureApplied = false
    resetOverlayCaches()
end

local function detachOverlay(clearOwner)
    if overlay.canvas and overlay.canvas:IsValid() then
        safeCall("Remove overlay canvas", function()
            overlay.canvas:RemoveFromParent()
        end)
    end

    clearOverlayWidgetRefs(clearOwner)
end

local function sameObject(a, b)
    return a and b and a:IsValid() and b:IsValid() and a:GetAddress() == b:GetAddress()
end

local function lockKeyForDebounce(unlock)
    ExecuteWithDelay(Config.KeyDebounceMs or 250, unlock)
end

local function isAbsolutePath(path)
    return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil
end

local function fileExists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

local function normalizePath(path)
    return (path:gsub("/", "\\"))
end

local function joinPath(basePath, fileName)
    return normalizePath(basePath):gsub("[\\/]+$", "") .. "\\" .. fileName
end

local function getScriptAssetRoot()
    if not debug or not debug.getinfo then return nil end

    local source = debug.getinfo(1, "S").source
    if not source or source:sub(1, 1) ~= "@" then return nil end

    local scriptPath = source:sub(2):gsub("\\", "/")
    local modRoot = scriptPath:match("^(.*)/Scripts/[^/]+$")
    if not modRoot then return nil end

    return normalizePath(modRoot .. "/Scripts")
end

local function getAssetPath(fileName)
    if isAbsolutePath(fileName) then return fileName end

    local scriptAssetRoot = getScriptAssetRoot()
    if not scriptAssetRoot then return fileName end

    return joinPath(scriptAssetRoot, fileName)
end

local function findDefaultObject(path)
    local object = StaticFindObject(path)
    if object and object:IsValid() then return object end
    return CreateInvalidObject()
end

local function getRenderingLibrary()
    if renderingLibrary:IsValid() then return renderingLibrary end
    renderingLibrary = findDefaultObject("/Script/Engine.Default__KismetRenderingLibrary")
    return renderingLibrary
end

local function getWidgetLayoutLibrary()
    if widgetLayoutLibrary:IsValid() then return widgetLayoutLibrary end
    widgetLayoutLibrary = findDefaultObject("/Script/UMG.Default__WidgetLayoutLibrary")
    return widgetLayoutLibrary
end

local function loadTexture(fileName, attemptedFlagName)
    local target = arrowTexture
    if attemptedFlagName == "map" then
        target = mapTexture
    elseif attemptedFlagName == "pixel" then
        target = pixelTexture
    end
    if target:IsValid() then return target end

    if attemptedFlagName == "map" and textureLoadAttempted then return target end
    if attemptedFlagName == "pixel" and pixelLoadAttempted then return target end
    if attemptedFlagName == "arrow" and arrowLoadAttempted then return target end

    local world = UEHelpers.GetWorld()
    local renderer = getRenderingLibrary()
    if not world:IsValid() or not renderer:IsValid() then return target end

    local path = getAssetPath(fileName)
    if not fileExists(path) then
        log("Texture not found: " .. path)
        if attemptedFlagName == "map" then
            textureLoadAttempted = true
        elseif attemptedFlagName == "pixel" then
            pixelLoadAttempted = true
        else
            arrowLoadAttempted = true
        end
        return target
    end

    if attemptedFlagName == "map" then
        textureLoadAttempted = true
    elseif attemptedFlagName == "pixel" then
        pixelLoadAttempted = true
    else
        arrowLoadAttempted = true
    end

    local texture = safeCall("ImportFileAsTexture2D(" .. fileName .. ")", function()
        return renderer:ImportFileAsTexture2D(world, path)
    end)

    if texture and texture:IsValid() then
        if attemptedFlagName == "map" then
            mapTexture = texture
        elseif attemptedFlagName == "pixel" then
            pixelTexture = texture
        else
            arrowTexture = texture
        end
        log("Texture loaded: " .. path)
        return texture
    end

    return target
end

local function loadMapTexture()
    return loadTexture(Config.Map.ImageFile or "mapgenie_world_cropped.png", "map")
end

local function loadPixelTexture()
    return loadTexture("pixel.png.lua", "pixel")
end

local function loadArrowTexture()
    return loadTexture((Config.Marker or {}).ImageFile or "MapArrowRight.png", "arrow")
end

local function findClass(shortName)
    if widgetClasses[shortName] and widgetClasses[shortName]:IsValid() then
        return widgetClasses[shortName]
    end

    local candidates = {
        "Class /Script/UMG." .. shortName,
        "/Script/UMG." .. shortName,
    }

    for _, candidate in ipairs(candidates) do
        local class = StaticFindObject(candidate)
        if class and class:IsValid() then
            widgetClasses[shortName] = class
            return class
        end
    end

    log("UMG class not found: " .. shortName)
    return CreateInvalidObject()
end

local function constructWidget(shortName, outer)
    local class = findClass(shortName)
    if not class:IsValid() or not outer or not outer:IsValid() then return CreateInvalidObject() end

    local widget = safeCall("StaticConstructObject(" .. shortName .. ")", function()
        return StaticConstructObject(class, outer)
    end)

    if widget and widget:IsValid() then return widget end
    return CreateInvalidObject()
end

local function findHudScreen()
    local controller = UEHelpers.GetPlayerController()
    if controller:IsValid() and controller.MyHUD and controller.MyHUD:IsValid() then
        local hud = controller.MyHUD
        if hud.HUDScreen and hud.HUDScreen:IsValid() then return hud.HUDScreen end
    end

    local screen = FindFirstOf("WBP_HUDScreen_C")
    if screen and screen:IsValid() then return screen end

    screen = FindFirstOf("WBP_HUDScreen")
    if screen and screen:IsValid() then return screen end

    return CreateInvalidObject()
end

local function getRootWidget(hudScreen)
    if not hudScreen or not hudScreen:IsValid() then return CreateInvalidObject() end
    if hudScreen.WidgetTree and hudScreen.WidgetTree:IsValid() and hudScreen.WidgetTree.RootWidget and hudScreen.WidgetTree.RootWidget:IsValid() then
        return hudScreen.WidgetTree.RootWidget
    end
    return CreateInvalidObject()
end

local function findMainScreen()
    local screen = FindFirstOf("WBP_MainScreen_C")
    if screen and screen:IsValid() then return screen end

    screen = FindFirstOf("WBP_MainScreen")
    if screen and screen:IsValid() then return screen end

    return CreateInvalidObject()
end

local function getOverlayRootAndOuter(hudScreen)
    local mainScreen = findMainScreen()
    if mainScreen:IsValid() then
        local outer = mainScreen.WidgetTree and mainScreen.WidgetTree:IsValid() and mainScreen.WidgetTree or mainScreen
        if mainScreen.Layers and mainScreen.Layers:IsValid() then
            return mainScreen.Layers, outer
        end

        local mainRoot = getRootWidget(mainScreen)
        if mainRoot:IsValid() then return mainRoot, outer end
    end

    local hudRoot = getRootWidget(hudScreen)
    local hudOuter = hudScreen.WidgetTree and hudScreen.WidgetTree:IsValid() and hudScreen.WidgetTree or hudScreen
    return hudRoot, hudOuter
end

local function addToCanvas(parent, child)
    if not parent or not parent:IsValid() or not child or not child:IsValid() then return nil end

    local slot = safeCall("AddChildToCanvas", function()
        return parent:AddChildToCanvas(child)
    end)
    if slot and slot:IsValid() then return slot end

    slot = safeCall("AddChild", function()
        return parent:AddChild(child)
    end)
    if slot and slot:IsValid() then return slot end

    return nil
end

local function setWidgetVisibility(widget, visible)
    if widget and widget:IsValid() then
        widget:SetVisibility(visible and VISIBLE or HIDDEN)
    end
end

local function setCachedWidgetVisibility(cacheField, widget, visible)
    if overlay[cacheField] == visible then return end
    setWidgetVisibility(widget, visible)
    overlay[cacheField] = visible
end

local function setMarkerVisibility(visible)
    if overlay.lastMarkerVisible == visible then return end
    setWidgetVisibility(overlay.marker, visible)
    overlay.lastMarkerVisible = visible
end

local function setImageTexture(image, texture, tint)
    if not image or not image:IsValid() or not texture or not texture:IsValid() then return end
    safeCall("SetBrushFromTexture", function() image:SetBrushFromTexture(texture, false) end)
    safeCall("SetColorAndOpacity", function() image:SetColorAndOpacity(tint or { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }) end)
end

local function createImage(parent, outer, zOrder, texture, tint)
    local image = constructWidget("Image", outer or parent)
    if not image:IsValid() then return CreateInvalidObject(), nil end

    local slot = addToCanvas(parent, image)
    if slot and slot:IsValid() then slot:SetZOrder(zOrder or 0) end
    setImageTexture(image, texture, tint)
    image:SetVisibility(VISIBLE)
    return image, slot
end

local function setSlotAnchors(slot, minX, minY, maxX, maxY, zOrder)
    if not slot or not slot:IsValid() then return end
    slot:SetMinimum(vec2(minX, minY))
    slot:SetMaximum(vec2(maxX, maxY))
    slot:SetAlignment(vec2(0.0, 0.0))
    slot:SetAutoSize(false)
    if zOrder then slot:SetZOrder(zOrder) end
end

local function setSlotFill(slot, zOrder)
    if not slot or not slot:IsValid() then return end
    slot:SetMinimum(vec2(0.0, 0.0))
    slot:SetMaximum(vec2(1.0, 1.0))
    slot:SetPosition(vec2(0.0, 0.0))
    slot:SetSize(vec2(0.0, 0.0))
    slot:SetAlignment(vec2(0.0, 0.0))
    slot:SetAutoSize(false)
    if zOrder then slot:SetZOrder(zOrder) end
end

local function setSlotTopLeft(slot, zOrder)
    setSlotAnchors(slot, 0.0, 0.0, 0.0, 0.0, zOrder)
end

local function attachOverlay()
    local hudScreen = findHudScreen()
    if not hudScreen:IsValid() then
        if not attachAttemptLogged then
            attachAttemptLogged = true
            log("WBP_HUDScreen is not available yet, waiting...")
        end
        return false
    end

    local root, widgetOuter = getOverlayRootAndOuter(hudScreen)
    if not root:IsValid() then
        if not attachAttemptLogged then
            attachAttemptLogged = true
            log("HUD/MainScreen RootWidget not found, waiting...")
        end
        return false
    end

    if overlay.canvas:IsValid() and sameObject(overlay.hudScreen, hudScreen) and sameObject(overlay.root, root) then return true end
    if overlay.canvas:IsValid() then detachOverlay(false) end

    overlay.hudScreen = hudScreen
    overlay.root = root

    overlay.canvas = constructWidget("CanvasPanel", widgetOuter)
    if not overlay.canvas:IsValid() then return false end

    overlay.canvasSlot = addToCanvas(root, overlay.canvas)
    if not overlay.canvasSlot then
        log("Failed to add CanvasPanel to HUD root: " .. root:GetFullName())
        overlay.canvas = CreateInvalidObject()
        return false
    end
    setSlotFill(overlay.canvasSlot, 9999)

    resetOverlayCaches()
    overlay.lastCanvasVisible = false

    local pixel = loadPixelTexture()
    local map = loadMapTexture()

    overlay.dim, overlay.dimSlot = createImage(overlay.canvas, widgetOuter, 980, pixel, COLOR_BLACK)
    setSlotFill(overlay.dimSlot, 980)
    overlay.viewport = constructWidget("CanvasPanel", widgetOuter)
    overlay.viewportSlot = overlay.viewport:IsValid() and addToCanvas(overlay.canvas, overlay.viewport) or nil
    if overlay.viewportSlot then setSlotTopLeft(overlay.viewportSlot, 990) end
    safeCall("Viewport ClipToBounds", function() overlay.viewport:SetClipping(1) end)
    local mapParent = overlay.viewport:IsValid() and overlay.viewport or overlay.canvas
    overlay.map, overlay.mapSlot = createImage(mapParent, widgetOuter, 0, map, COLOR_WHITE)
    setSlotTopLeft(overlay.mapSlot, 0)
    overlay.mapTextureApplied = map:IsValid()
    overlay.borderTop, overlay.borderTopSlot = createImage(overlay.canvas, widgetOuter, 991, pixel, COLOR_BORDER)
    setSlotTopLeft(overlay.borderTopSlot, 991)
    overlay.borderRight, overlay.borderRightSlot = createImage(overlay.canvas, widgetOuter, 991, pixel, COLOR_BORDER)
    setSlotTopLeft(overlay.borderRightSlot, 991)
    overlay.borderBottom, overlay.borderBottomSlot = createImage(overlay.canvas, widgetOuter, 991, pixel, COLOR_BORDER)
    setSlotTopLeft(overlay.borderBottomSlot, 991)
    overlay.borderLeft, overlay.borderLeftSlot = createImage(overlay.canvas, widgetOuter, 991, pixel, COLOR_BORDER)
    setSlotTopLeft(overlay.borderLeftSlot, 991)
    local arrow = loadArrowTexture()
    overlay.marker, overlay.markerSlot = createImage(overlay.canvas, widgetOuter, 1001, arrow, COLOR_MARKER)
    setSlotTopLeft(overlay.markerSlot, 1001)
    overlay.markerTextureApplied = arrow:IsValid()

    if isFogEnabled() then
        local fogTex = loadFogTexture()
        local fogParent = overlay.viewport:IsValid() and overlay.viewport or overlay.canvas
        overlay.fog, overlay.fogSlot = createImage(fogParent, widgetOuter, 1, fogTex, COLOR_WHITE)
        setSlotTopLeft(overlay.fogSlot, 1)
        overlay.fogTextureApplied = fogTex:IsValid()
    end

    overlay.marker:SetRenderTransformPivot(vec2(0.5, 0.5))
    overlay.canvas:SetVisibility(HIDDEN)

    if not overlayAttachedLogged then
        overlayAttachedLogged = true
        log("UMG overlay attached to HUD: " .. root:GetFullName())
    end

    return true
end

local function ensureOverlayAttached()
    if overlay.canvas:IsValid() then return true end
    return attachOverlay()
end

local function setSlotRect(slot, x, y, width, height, zOrder)
    if not slot or not slot:IsValid() then return end
    slot:SetPosition(vec2(x, y))
    slot:SetSize(vec2(width, height))
    if zOrder then slot:SetZOrder(zOrder) end
end

local function setWidgetRenderTranslation(widget, x, y)
    if not widget or not widget:IsValid() then return end
    widget:SetRenderTranslation(vec2(x, y))
end

local function getViewportSize()
    local world = UEHelpers.GetWorld()
    local layout = getWidgetLayoutLibrary()
    if world:IsValid() and layout:IsValid() then
        local size = safeCall("GetViewportSize", function()
            return layout:GetViewportSize(world)
        end)
        if size and size.X and size.Y and size.X > 0 and size.Y > 0 then
            local scale = safeCall("GetViewportScale", function()
                return layout:GetViewportScale(world)
            end)
            if scale and scale > 0 and scale ~= 1.0 then
                return size.X / scale, size.Y / scale
            end
            return size.X, size.Y
        end
    end
    return 1920, 1080
end

local function getViewportPollSampleCount()
    local interval = Config.UpdateIntervalMs or 100
    if largeMapOpen and Config.LargeMap and Config.LargeMap.UpdateIntervalMs then
        interval = Config.LargeMap.UpdateIntervalMs
    elseif Config.Minimap and Config.Minimap.UpdateIntervalMs then
        interval = Config.Minimap.UpdateIntervalMs
    end
    local pollInterval = Config.ViewportPollIntervalMs or 1000
    if interval <= 0 then return 10 end
    local count = math.floor((pollInterval / interval) + 0.5)
    if count < 1 then return 1 end
    return count
end

local function getCachedViewportSize(force)
    if force or viewportDirty or viewportPollCountdown <= 0 then
        cachedScreenW, cachedScreenH = getViewportSize()
        viewportDirty = false
        viewportPollCountdown = getViewportPollSampleCount()
    else
        viewportPollCountdown = viewportPollCountdown - 1
    end

    return cachedScreenW, cachedScreenH
end

local function getAspectRatio()
    local width = Config.Map.ImageWidth or 1
    local height = Config.Map.ImageHeight or 1
    if height == 0 then return 1.0 end
    return width / height
end

local function fitToAspect(maxW, maxH)
    local aspect = getAspectRatio()
    local width = maxW
    local height = width / aspect
    if height > maxH then
        height = maxH
        width = height * aspect
    end
    return width, height
end

local function getLayoutBox(layout, screenW, screenH)
    local maxW = layout.Width or (screenW * (layout.WidthRatio or 0.25))
    local maxH = layout.Height or (screenH * (layout.HeightRatio or 0.25))
    local width, height = fitToAspect(maxW, maxH)
    local anchor = layout.Anchor or "TopRight"
    local x = layout.X or 0
    local y = layout.Y or 0

    if anchor == "TopRight" then
        x = screenW - width - (layout.MarginRight or 16)
        y = layout.MarginTop or 16
    elseif anchor == "TopLeft" then
        x = layout.MarginLeft or 16
        y = layout.MarginTop or 16
    elseif anchor == "BottomRight" then
        x = screenW - width - (layout.MarginRight or 16)
        y = screenH - height - (layout.MarginBottom or 16)
    elseif anchor == "BottomLeft" then
        x = layout.MarginLeft or 16
        y = screenH - height - (layout.MarginBottom or 16)
    elseif anchor == "Center" then
        x = ((screenW - width) / 2.0) + (layout.OffsetX or 0)
        y = ((screenH - height) / 2.0) + (layout.OffsetY or 0)
    end

    return x, y, width, height
end

local function getAxisValue(vector, axisName)
    if not vector then return nil end
    return vector[axisName or "X"]
end

local function getBoundsForLocation(worldX, worldY)
    local mapConfig = Config.Map
    if mapConfig.AutoCenterOnFirstPlayerPosition ~= false then
        if not runtimeBounds then
            local spanX = mapConfig.AutoCenterSpanX or (mapConfig.WorldMaxX - mapConfig.WorldMinX)
            local spanY = mapConfig.AutoCenterSpanY or (mapConfig.WorldMaxY - mapConfig.WorldMinY)
            local initialU = clamp(mapConfig.InitialMapU or 0.5, 0.0, 1.0)
            local initialV = clamp(mapConfig.InitialMapV or 0.5, 0.0, 1.0)
            if mapConfig.InvertVertical ~= false then initialV = 1.0 - initialV end

            runtimeBounds = {
                MinX = worldX - (spanX * initialU),
                MaxX = worldX + (spanX * (1.0 - initialU)),
                MinY = worldY - (spanY * initialV),
                MaxY = worldY + (spanY * (1.0 - initialV)),
            }

            if not calibrationLogged then
                calibrationLogged = true
                log(string.format("Auto calibration: player=(%.1f, %.1f), bounds X=%.1f..%.1f Y=%.1f..%.1f", worldX, worldY, runtimeBounds.MinX, runtimeBounds.MaxX, runtimeBounds.MinY, runtimeBounds.MaxY))
            end
        end
        return runtimeBounds
    end

    return configuredBounds
end

local function mercatorY(lat)
    local rad = lat * math.pi / 180.0
    return (1.0 - (math.log(math.tan(rad) + (1.0 / math.cos(rad))) / math.pi)) / 2.0
end

local function getMapGenieProjection()
    if mapGenieProjection then return mapGenieProjection end

    local mapConfig = Config.Map
    local west = mapConfig.BoundsWest
    local east = mapConfig.BoundsEast
    local south = mapConfig.BoundsSouth
    local north = mapConfig.BoundsNorth
    if not west or not east or not south or not north or east == west or north == south then
        mapGenieProjection = { Valid = false }
        return mapGenieProjection
    end

    local top = mercatorY(north)
    local bottom = mercatorY(south)
    if bottom == top then
        mapGenieProjection = { Valid = false }
        return mapGenieProjection
    end

    mapGenieProjection = {
        Valid = true,
        West = west,
        Top = top,
        InvLngRange = 1.0 / (east - west),
        InvMercatorRange = 1.0 / (bottom - top),
    }
    return mapGenieProjection
end

local function worldToMapGenieUV(worldX, worldY)
    local mapConfig = Config.Map
    local projection = getMapGenieProjection()
    if not projection.Valid then return nil, nil end

    local lng = (worldX * mapConfig.LngFromXScale) + mapConfig.LngFromXOffset
    local lat = (worldY * mapConfig.LatFromYScale) + mapConfig.LatFromYOffset
    local u = (lng - projection.West) * projection.InvLngRange
    local v = (mercatorY(lat) - projection.Top) * projection.InvMercatorRange

    if mapConfig.ClampMarkerToMap ~= false then
        u = clamp(u, 0.0, 1.0)
        v = clamp(v, 0.0, 1.0)
    end

    return u, v
end

isFogEnabled = function()
    return Config.FogOfWar and Config.FogOfWar.Enabled ~= false
end

local function initFogGrid()
    local fogCfg = Config.FogOfWar or {}
    local w = fogCfg.GridWidth or 57
    local h = fogCfg.GridHeight or 24
    fogGrid = {}
    for y = 1, h do
        fogGrid[y] = {}
        for x = 1, w do
            fogGrid[y][x] = false
        end
    end
end

local function getFogSavePath()
    local fogCfg = Config.FogOfWar or {}
    return getAssetPath(fogCfg.SaveFile or "fog_state.dat")
end

local function saveFogState()
    local fogCfg = Config.FogOfWar or {}
    local w = fogCfg.GridWidth or 57
    local h = fogCfg.GridHeight or 24
    local path = getFogSavePath()
    local file = io.open(path, "w")
    if not file then return end
    for y = 1, h do
        local row = {}
        for x = 1, w do
            row[x] = (fogGrid[y] and fogGrid[y][x]) and "1" or "0"
        end
        file:write(table.concat(row) .. "\n")
    end
    file:close()
end

local function loadFogState()
    local fogCfg = Config.FogOfWar or {}
    local w = fogCfg.GridWidth or 57
    local h = fogCfg.GridHeight or 24
    local path = getFogSavePath()
    local file = io.open(path, "r")
    if not file then return false end
    for y = 1, h do
        local line = file:read("*l")
        if not line then break end
        if not fogGrid[y] then fogGrid[y] = {} end
        for x = 1, math.min(w, #line) do
            fogGrid[y][x] = line:sub(x, x) == "1"
        end
    end
    file:close()
    return true
end

local function getFogTGAPath()
    return getAssetPath("fog_overlay.tga")
end

local function writeFogTGA()
    local fogCfg = Config.FogOfWar or {}
    local w = fogCfg.GridWidth or 57
    local h = fogCfg.GridHeight or 24
    local alpha = math.floor((fogCfg.FogAlpha or 0.95) * 255)
    local path = getFogTGAPath()

    local file = io.open(path, "wb")
    if not file then
        log("Failed to write fog TGA: " .. path)
        return false
    end

    file:write(string.char(
        0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        w % 256, math.floor(w / 256),
        h % 256, math.floor(h / 256),
        32, 0x28
    ))

    local revealed = string.char(0, 0, 0, 0)
    local fog = string.char(0, 0, 0, alpha)
    local parts = {}
    for y = 1, h do
        local row = fogGrid[y]
        for x = 1, w do
            parts[#parts + 1] = (row and row[x]) and revealed or fog
        end
    end

    file:write(table.concat(parts))
    file:close()
    return true
end

local function worldToUV(worldX, worldY)
    local mapConfig = Config.Map
    if mapConfig.ProjectionMode == "MapGenie" then
        return worldToMapGenieUV(worldX, worldY)
    end
    local bounds = getBoundsForLocation(worldX, worldY)
    local rangeX = bounds.MaxX - bounds.MinX
    local rangeY = bounds.MaxY - bounds.MinY
    if rangeX == 0 or rangeY == 0 then return nil, nil end
    local u = (worldX - bounds.MinX) / rangeX
    local v = (worldY - bounds.MinY) / rangeY
    if mapConfig.InvertVertical ~= false then v = 1.0 - v end
    u = clamp(u, 0.0, 1.0)
    v = clamp(v, 0.0, 1.0)
    return u, v
end

local function updateFogAtPosition(worldX, worldY)
    if not isFogEnabled() then return end

    local u, v = worldToUV(worldX, worldY)
    if not u or not v then return end

    local fogCfg = Config.FogOfWar or {}
    local fw = fogCfg.GridWidth or 57
    local fh = fogCfg.GridHeight or 24
    local cx = clamp(math.floor(u * fw) + 1, 1, fw)
    local cy = clamp(math.floor(v * fh) + 1, 1, fh)

    if cx == fogLastCellX and cy == fogLastCellY then return end
    fogLastCellX = cx
    fogLastCellY = cy

    local radius = fogCfg.RevealRadius or 2
    local changed = false
    for dy = -radius, radius do
        local gy = cy + dy
        if gy >= 1 and gy <= fh then
            if not fogGrid[gy] then fogGrid[gy] = {} end
            for dx = -radius, radius do
                local gx = cx + dx
                if gx >= 1 and gx <= fw then
                    if not fogGrid[gy][gx] then
                        fogGrid[gy][gx] = true
                        changed = true
                    end
                end
            end
        end
    end

    if changed then
        fogSaveDirty = true
        scheduleFogFlush()
    end
end

loadFogTexture = function(forceReload)
    if not forceReload and fogTexture:IsValid() then return fogTexture end

    local path = getFogTGAPath()
    if not fileExists(path) then return fogTexture end

    local world = UEHelpers.GetWorld()
    local renderer = getRenderingLibrary()
    if not world:IsValid() or not renderer:IsValid() then return fogTexture end

    local tex = safeCall("ImportFogTexture", function()
        return renderer:ImportFileAsTexture2D(world, path)
    end)

    if tex and tex:IsValid() then
        fogTexture = tex
    end

    return fogTexture
end

-- Fog persistence is throttled off the travel hot path. Crossing into new
-- cells only updates the in-memory grid; the TGA write + texture refresh are
-- coalesced (VisualThrottleMs), and the .dat save is rarer (SaveThrottleMs)
-- plus a guaranteed flush on map change.
scheduleFogFlush = function()
    if fogFlushPending then return end
    fogFlushPending = true
    local delay = (Config.FogOfWar and Config.FogOfWar.VisualThrottleMs) or 750
    ExecuteWithDelay(delay, function()
        ExecuteInGameThread(flushFogVisual)
    end)
end

flushFogVisual = function()
    fogFlushPending = false
    if not isFogEnabled() then return end
    safeCall("Fog TGA write", writeFogTGA)
    if overlay.fog and overlay.fog:IsValid() then
        local fogTex = loadFogTexture(true)
        if fogTex and fogTex:IsValid() then
            setImageTexture(overlay.fog, fogTex, COLOR_WHITE)
            overlay.fogTextureApplied = true
        end
    end
    scheduleFogSave()
end

scheduleFogSave = function()
    if fogSavePending or not fogSaveDirty then return end
    fogSavePending = true
    local delay = (Config.FogOfWar and Config.FogOfWar.SaveThrottleMs) or 20000
    ExecuteWithDelay(delay, function()
        ExecuteInGameThread(flushFogSave)
    end)
end

flushFogSave = function()
    fogSavePending = false
    if fogSaveDirty then
        safeCall("Fog state save", saveFogState)
        fogSaveDirty = false
    end
end

local function getPlayerLocationAndForward()
    pawnCheckCountdown = pawnCheckCountdown - 1
    if pawnCheckCountdown <= 0 or not cachedPawn:IsValid() then
        cachedPawn = UEHelpers.GetPlayer()
        pawnCheckCountdown = PAWN_CHECK_INTERVAL
    end
    if not cachedPawn:IsValid() then return nil, nil end
    return cachedPawn:K2_GetActorLocation(), cachedPawn:GetActorForwardVector()
end

local function sampleToMapPoint(sample, mapX, mapY, mapW, mapH, out)
    local mapConfig = Config.Map
    local u, v

    if mapConfig.ProjectionMode == "MapGenie" then
        u, v = worldToMapGenieUV(sample.worldX, sample.worldY)
        if not u or not v then return nil end
    else
        local bounds = getBoundsForLocation(sample.worldX, sample.worldY)
        local rangeX = bounds.MaxX - bounds.MinX
        local rangeY = bounds.MaxY - bounds.MinY
        if rangeX == 0 or rangeY == 0 then return nil end

        u = (sample.worldX - bounds.MinX) / rangeX
        v = (sample.worldY - bounds.MinY) / rangeY
        if mapConfig.InvertVertical ~= false then v = 1.0 - v end
        if mapConfig.ClampMarkerToMap ~= false then
            u = clamp(u, 0.0, 1.0)
            v = clamp(v, 0.0, 1.0)
        end
    end

    out.X = mapX + (u * mapW)
    out.Y = mapY + (v * mapH)
    out.U = u
    out.V = v
    out.ForwardX = sample.forwardX
    out.ForwardY = sample.forwardY
    return out
end

local function isMapActive()
    return largeMapOpen or (mapVisible and Config.Minimap and Config.Minimap.Enabled ~= false)
end

local function needsHiddenApply()
    return overlay.canvas:IsValid() and overlay.lastCanvasVisible ~= false
end

local function markOverlayStateDirty(forceViewport)
    overlayGeneration = overlayGeneration + 1
    resetOverlayCaches()
    lastWorldX = nil
    if forceViewport ~= false then viewportDirty = true end
end

local function hasPlayerMoved(worldX, worldY, forwardX, forwardY)
    if not lastWorldX then return true end
    local threshold = (Config.Marker or {}).WorldMoveThreshold or 50.0
    local dx = worldX - lastWorldX
    local dy = worldY - lastWorldY
    if (dx * dx + dy * dy) >= (threshold * threshold) then return true end
    local dfx = forwardX - (lastForwardX or 0)
    local dfy = forwardY - (lastForwardY or 0)
    if (dfx * dfx + dfy * dfy) > 0.001 then return true end
    return false
end

local function collectFrameSample()
    local active = isMapActive()
    if not active and not needsHiddenApply() then return nil end
    if not ensureOverlayAttached() then return nil end

    local screenW, screenH = getCachedViewportSize(viewportDirty)
    local sample = frameSample
    sample.generation = overlayGeneration
    sample.screenW = screenW
    sample.screenH = screenH

    if not active then
        sample.hidden = true
        return sample
    end

    local location, forward = getPlayerLocationAndForward()
    if not location then return nil end

    local worldX = getAxisValue(location, Config.Map.HorizontalAxis) or 0.0
    local worldY = getAxisValue(location, Config.Map.VerticalAxis) or 0.0
    local forwardX = forward and (getAxisValue(forward, Config.Map.HorizontalAxis) or 1.0) or 1.0
    local forwardY = forward and (getAxisValue(forward, Config.Map.VerticalAxis) or 0.0) or 0.0

    if not hasPlayerMoved(worldX, worldY, forwardX, forwardY) and not viewportDirty then
        return nil
    end

    lastWorldX = worldX
    lastWorldY = worldY
    lastForwardX = forwardX
    lastForwardY = forwardY

    updateFogAtPosition(worldX, worldY)

    sample.hidden = false
    sample.worldX = worldX
    sample.worldY = worldY
    sample.forwardX = forwardX
    sample.forwardY = forwardY

    return sample
end

local function buildDrawState(sample)
    local state = drawState
    local shouldShow = isMapActive()

    state.generation = sample.generation
    state.shouldShow = shouldShow and not sample.hidden
    state.largeMapOpen = largeMapOpen
    state.screenW = sample.screenW
    state.screenH = sample.screenH
    state.layout = nil
    state.point = nil
    state.markerXKey = nil
    state.markerYKey = nil
    state.markerAngleKey = nil
    state.markerSize = nil
    state.angle = 0.0
    state.angleKey = nil

    if not shouldShow or sample.hidden then
        state.shouldShow = false
        return state
    end

    local layout = largeMapOpen and Config.LargeMap or Config.Minimap
    local x, y, width, height = getLayoutBox(layout, sample.screenW, sample.screenH)
    local thickness = layout.BorderThickness or 2
    local point = nil
    local angle = 0.0
    local angleKey = 0

    if shouldShow then
        point = sampleToMapPoint(sample, x, y, width, height, mapPoint)
        if point then
            local forwardX = point.ForwardX or 1.0
            local forwardY = point.ForwardY or 0.0
            if Config.Map.ProjectionMode ~= "MapGenie" and Config.Map.InvertVertical ~= false then forwardY = -forwardY end
            angle = math.deg(math.atan(forwardY, forwardX))

            -- Zoom + follow-cam: scroll an oversized map under a centred marker.
            -- zoom == 1.0 collapses to the original "whole map fills the box" behaviour.
            local zoom = largeMapOpen and largeMapZoom or minimapZoom
            if not zoom or zoom < 1.0 then zoom = 1.0 end
            local mapW = width * zoom
            local mapH = height * zoom
            local u = point.U or 0.5
            local v = point.V or 0.5
            -- Which map point sits at box centre. Minimap follows the player; the
            -- large map centres on the player when opened, then pans freely
            -- (largeMapViewU/V), decoupled from the player position.
            local cu, cv = u, v
            if largeMapOpen then
                if largeMapViewU == nil then largeMapViewU = u end
                if largeMapViewV == nil then largeMapViewV = v end
                cu = largeMapViewU
                cv = largeMapViewV
            end
            -- Offset of the map's top-left inside the box, clamped so we never
            -- scroll past the image edges (no black gap at map borders).
            local mapLocalX = clamp((width * 0.5) - (cu * mapW), width - mapW, 0.0)
            local mapLocalY = clamp((height * 0.5) - (cv * mapH), height - mapH, 0.0)
            state.mapLocalX = mapLocalX
            state.mapLocalY = mapLocalY
            state.mapW = mapW
            state.mapH = mapH
            -- Marker stays at the PLAYER position (u,v) within whatever view is
            -- shown; drifts off-centre while panning, hidden once it leaves the box.
            local markerX = x + (u * mapW) + mapLocalX
            local markerY = y + (v * mapH) + mapLocalY
            state.markerX = markerX
            state.markerY = markerY
            state.markerOnScreen = markerX >= x and markerX <= (x + width)
                and markerY >= y and markerY <= (y + height)

            local marker = Config.Marker or {}
            local moveThreshold = marker.MoveThresholdPixels or 1
            local headingThreshold = marker.HeadingThresholdDegrees or 1
            angleKey = quantize(angle, headingThreshold)
            state.markerXKey = quantize(markerX, moveThreshold)
            state.markerYKey = quantize(markerY, moveThreshold)
            state.markerAngleKey = angleKey
            state.markerSize = marker.Size or 8
        end
    end

    state.x = x
    state.y = y
    state.width = width
    state.height = height
    state.thickness = thickness
    state.layout = layout
    state.layoutXKey = math.floor(x)
    state.layoutYKey = math.floor(y)
    state.layoutWidthKey = math.floor(width)
    state.layoutHeightKey = math.floor(height)
    state.layoutMapAlpha = layout.MapAlpha or 1.0
    state.layoutBackgroundAlpha = layout.BackgroundAlpha or 0.45
    state.layoutDimVisible = largeMapOpen and layout.DimBackground ~= false
    state.point = point
    state.angle = angle
    state.angleKey = angleKey
    return state
end

local function hasLayoutChanged(state)
    return overlay.lastLayoutLarge ~= state.largeMapOpen
        or overlay.lastLayoutScreenW ~= state.screenW
        or overlay.lastLayoutScreenH ~= state.screenH
        or overlay.lastLayoutXKey ~= state.layoutXKey
        or overlay.lastLayoutYKey ~= state.layoutYKey
        or overlay.lastLayoutWidthKey ~= state.layoutWidthKey
        or overlay.lastLayoutHeightKey ~= state.layoutHeightKey
        or overlay.lastLayoutMapAlpha ~= state.layoutMapAlpha
        or overlay.lastLayoutBackgroundAlpha ~= state.layoutBackgroundAlpha
        or overlay.lastLayoutBorderThickness ~= state.thickness
        or overlay.lastLayoutDimVisible ~= state.layoutDimVisible
end

local function rememberLayoutState(state)
    overlay.lastLayoutLarge = state.largeMapOpen
    overlay.lastLayoutScreenW = state.screenW
    overlay.lastLayoutScreenH = state.screenH
    overlay.lastLayoutXKey = state.layoutXKey
    overlay.lastLayoutYKey = state.layoutYKey
    overlay.lastLayoutWidthKey = state.layoutWidthKey
    overlay.lastLayoutHeightKey = state.layoutHeightKey
    overlay.lastLayoutMapAlpha = state.layoutMapAlpha
    overlay.lastLayoutBackgroundAlpha = state.layoutBackgroundAlpha
    overlay.lastLayoutBorderThickness = state.thickness
    overlay.lastLayoutDimVisible = state.layoutDimVisible
end

local function applyDrawState(state)
    if not state then return end
    if state.generation ~= overlayGeneration then return end
    if not ensureOverlayAttached() then return end

    setCachedWidgetVisibility("lastCanvasVisible", overlay.canvas, state.shouldShow)
    if not state.shouldShow then
        return
    end

    local layout = state.layout
    local layoutChanged = hasLayoutChanged(state)

    if layoutChanged and overlay.canvasSlot and overlay.canvasSlot:IsValid() then
        setSlotFill(overlay.canvasSlot, 9999)
    end

    if not overlay.mapTextureApplied then
        local map = loadMapTexture()
        if map:IsValid() then
            COLOR_WHITE.A = layout.MapAlpha or 1.0
            setImageTexture(overlay.map, map, COLOR_WHITE)
            COLOR_WHITE.A = 1.0
            overlay.mapTextureApplied = true
        end
    elseif layoutChanged and overlay.map:IsValid() then
        COLOR_WHITE.A = layout.MapAlpha or 1.0
        overlay.map:SetColorAndOpacity(COLOR_WHITE)
        COLOR_WHITE.A = 1.0
    end

    if not overlay.markerTextureApplied then
        local arrow = loadArrowTexture()
        if arrow:IsValid() then
            setImageTexture(overlay.marker, arrow, COLOR_MARKER)
            overlay.markerTextureApplied = true
        end
    end

    if layoutChanged then
        rememberLayoutState(state)
        setCachedWidgetVisibility("lastDimVisible", overlay.dim, state.layoutDimVisible)
        setSlotFill(overlay.dimSlot, 980)
        if overlay.dim:IsValid() then
            COLOR_BLACK.A = layout.BackgroundAlpha or 0.45
            overlay.dim:SetColorAndOpacity(COLOR_BLACK)
        end

        setSlotRect(overlay.viewportSlot, state.x, state.y, state.width, state.height, 990)
        setSlotRect(overlay.borderTopSlot, state.x, state.y, state.width, state.thickness, 991)
        setSlotRect(overlay.borderRightSlot, state.x + state.width - state.thickness, state.y, state.thickness, state.height, 991)
        setSlotRect(overlay.borderBottomSlot, state.x, state.y + state.height - state.thickness, state.width, state.thickness, 991)
        setSlotRect(overlay.borderLeftSlot, state.x, state.y, state.thickness, state.height, 991)
    end

    if isFogEnabled() and overlay.fog:IsValid() then
        if fogDirty then
            fogDirty = false
            local fogTex = loadFogTexture(true)
            if fogTex:IsValid() then
                setImageTexture(overlay.fog, fogTex, COLOR_WHITE)
                overlay.fogTextureApplied = true
            end
        elseif not overlay.fogTextureApplied then
            local fogTex = loadFogTexture()
            if fogTex:IsValid() then
                setImageTexture(overlay.fog, fogTex, COLOR_WHITE)
                overlay.fogTextureApplied = true
            end
        end
    end

    local hasPoint = state.point ~= nil
    setMarkerVisibility(hasPoint and state.markerOnScreen ~= false)
    if not hasPoint then
        return
    end

    -- Scroll the map (and fog, locked to it) to follow the player.
    setSlotRect(overlay.mapSlot, state.mapLocalX, state.mapLocalY, state.mapW, state.mapH, 0)
    if isFogEnabled() and overlay.fog:IsValid() then
        setSlotRect(overlay.fogSlot, state.mapLocalX, state.mapLocalY, state.mapW, state.mapH, 1)
    end

    local size = state.markerSize or 8
    local markerChanged = overlay.lastMarkerXKey ~= state.markerXKey
        or overlay.lastMarkerYKey ~= state.markerYKey
        or overlay.lastMarkerAngleKey ~= state.markerAngleKey
        or overlay.lastMarkerSize ~= size
    if not markerChanged then
        return
    end

    local shapeChanged = overlay.lastMarkerSize ~= size
    overlay.lastMarkerXKey = state.markerXKey
    overlay.lastMarkerYKey = state.markerYKey
    overlay.lastMarkerAngleKey = state.markerAngleKey
    overlay.lastMarkerSize = size

    if shapeChanged then
        setSlotRect(overlay.markerSlot, 0.0, 0.0, size * 2, size * 2, 1001)
    end
    setWidgetRenderTranslation(overlay.marker, state.markerX - size, state.markerY - size)

    if overlay.lastHeadingAngleKey ~= state.angleKey then
        overlay.lastHeadingAngleKey = state.angleKey
        overlay.marker:SetRenderTransformAngle(state.angle)
    end
end

local function processFrameSample(sample)
    if not sample then return end
    local state = buildDrawState(sample)
    applyDrawState(state)
end

local function resetOverlay()
    detachOverlay(true)
    markOverlayStateDirty(true)
    runtimeBounds = nil
    overlayAttachedLogged = false
    attachAttemptLogged = false
    textureLoadAttempted = false
    pixelLoadAttempted = false
    arrowLoadAttempted = false
    mapTexture = CreateInvalidObject()
    pixelTexture = CreateInvalidObject()
    arrowTexture = CreateInvalidObject()
    fogTexture = CreateInvalidObject()
    fogLastCellX = nil
    fogLastCellY = nil
    fogDirty = false
    fogFlushPending = false
    fogSavePending = false
    cachedPawn = CreateInvalidObject()
    pawnCheckCountdown = 0
    viewportPollCountdown = 0
    lastWorldX = nil
    lastWorldY = nil
    lastForwardX = nil
    lastForwardY = nil
    attachRetryIndex = 1
end

local function gameThreadUpdate()
    sampleQueued = false
    local sample = collectFrameSample()
    if sample then
        processFrameSample(sample)
    end
end

local function gameThreadUpdateSafe()
    sampleQueued = false
    local ok, err = pcall(gameThreadUpdate)
    if not ok and not updateErrorLogged then
        updateErrorLogged = true
        log("Update failed: " .. tostring(err))
    end
end

local function requestUpdate()
    if sampleQueued then return end
    if not isMapActive() and not needsHiddenApply() then return end

    sampleQueued = true
    ExecuteInGameThread(gameThreadUpdateSafe)
end

local scheduleAttachAttempt

local function getActiveUpdateIntervalMs()
    local fallback = Config.UpdateIntervalMs or 200
    if largeMapOpen then
        return (Config.LargeMap and Config.LargeMap.UpdateIntervalMs) or fallback
    end
    return (Config.Minimap and Config.Minimap.UpdateIntervalMs) or fallback
end

local function cancelAttachAttempt()
    attachAttemptToken = attachAttemptToken + 1
    attachAttemptQueued = false
end

local function stopUpdateLoop()
    if not updateLoopActive then return end
    updateLoopToken = updateLoopToken + 1
    updateLoopActive = false
end

local function startUpdateLoop()
    if updateLoopActive then return end

    updateLoopActive = true
    updateLoopToken = updateLoopToken + 1
    local token = updateLoopToken

    local function tick()
        if token ~= updateLoopToken then return end
        if not isMapActive() and not needsHiddenApply() then
            updateLoopActive = false
            return
        end
        if not overlay.canvas:IsValid() then
            updateLoopActive = false
            if isMapActive() then scheduleAttachAttempt(Config.AttachInitialDelayMs or 250) end
            return
        end

        requestUpdate()
        ExecuteWithDelay(getActiveUpdateIntervalMs(), tick)
    end

    ExecuteWithDelay(getActiveUpdateIntervalMs(), tick)
end

local function restartUpdateLoop()
    stopUpdateLoop()
    startUpdateLoop()
end

local function getAttachRetryDelayMs()
    local delays = Config.AttachRetryDelaysMs or DEFAULT_ATTACH_RETRY_DELAYS_MS
    local count = #delays
    if count <= 0 then return 1000 end

    local index = attachRetryIndex
    if index > count then index = count end
    attachRetryIndex = attachRetryIndex + 1
    return delays[index] or 1000
end

local function runAttachAttemptSafe()
    attachAttemptQueued = false
    if overlay.canvas:IsValid() then
        attachRetryIndex = 1
        startUpdateLoop()
        requestUpdate()
        return
    end
    if not isMapActive() then return end

    local ok, attached = pcall(attachOverlay)
    if not ok then
        log("Attach failed: " .. tostring(attached))
        attached = false
    end

    if attached then
        attachRetryIndex = 1
        startUpdateLoop()
        requestUpdate()
    else
        scheduleAttachAttempt(getAttachRetryDelayMs())
    end
end

scheduleAttachAttempt = function(delayMs)
    if attachAttemptQueued or overlay.canvas:IsValid() or not isMapActive() then return end

    attachAttemptQueued = true
    attachAttemptToken = attachAttemptToken + 1
    local token = attachAttemptToken

    local function run()
        if token ~= attachAttemptToken then return end
        ExecuteInGameThread(function()
            if token ~= attachAttemptToken then return end
            runAttachAttemptSafe()
        end)
    end

    if delayMs and delayMs > 0 then
        ExecuteWithDelay(delayMs, run)
    else
        run()
    end
end

local function scheduleMapWork(delayMs, restartLoop)
    if isMapActive() then
        if overlay.canvas:IsValid() then
            if restartLoop then
                restartUpdateLoop()
            else
                startUpdateLoop()
            end
            requestUpdate()
        else
            scheduleAttachAttempt(delayMs or Config.AttachInitialDelayMs or 250)
        end
        return
    end

    cancelAttachAttempt()
    if needsHiddenApply() then requestUpdate() end
    stopUpdateLoop()
end

local function translateModifiers(modifierNames)
    local translated = {}
    if type(modifierNames) ~= "table" then return translated end

    for _, modifierName in ipairs(modifierNames) do
        local modifier = ModifierKey[modifierName]
        if modifier then
            translated[#translated + 1] = modifier
        else
            log("Invalid modifier in config: " .. tostring(modifierName))
        end
    end

    return translated
end

local function registerConfiguredKey(label, keyName, modifierNames, callback)
    if not keyName or keyName == "" then return end

    local key = Key[keyName]
    if not key then
        log("Invalid key for " .. label .. ": " .. tostring(keyName))
        return
    end

    local modifiers = translateModifiers(modifierNames)
    if #modifiers > 0 then
        RegisterKeyBind(key, modifiers, callback)
    else
        RegisterKeyBind(key, callback)
    end

    log(label .. " bind: " .. keyName)
end

registerConfiguredKey("OpenMap", Config.OpenMapKey, Config.OpenMapModifiers, function()
    if openToggleLocked then return end
    openToggleLocked = true
    lockKeyForDebounce(function() openToggleLocked = false end)

    largeMapOpen = not largeMapOpen
    if largeMapOpen then
        largeMapViewU = nil
        largeMapViewV = nil
    end
    log("Large map " .. (largeMapOpen and "opened" or "closed"))
    markOverlayStateDirty(true)
    scheduleMapWork(0, true)
end)

RegisterKeyBind(Key.ESCAPE, function()
    if not largeMapOpen then return end
    largeMapOpen = false
    log("Large map closed (ESC)")
    markOverlayStateDirty(true)
    scheduleMapWork(0, true)
end)

registerConfiguredKey("HideMap", Config.HideMapKey, Config.HideMapModifiers, function()
    if hideToggleLocked then return end
    hideToggleLocked = true
    lockKeyForDebounce(function() hideToggleLocked = false end)

    mapVisible = not mapVisible
    if not mapVisible then largeMapOpen = false end
    log("Minimap " .. (mapVisible and "shown" or "hidden"))
    markOverlayStateDirty(true)
    scheduleMapWork(0, true)
end)

local function adjustZoom(zoomIn)
    local layout = largeMapOpen and Config.LargeMap or (mapVisible and Config.Minimap or nil)
    if not layout then return end
    local step = layout.ZoomStep or 0.5
    local delta = zoomIn and step or -step
    local zmin = layout.ZoomMin or 1.0
    local zmax = layout.ZoomMax or (largeMapOpen and 6.0 or 8.0)
    if largeMapOpen then
        largeMapZoom = clamp(largeMapZoom + delta, zmin, zmax)
        log(string.format("Large map zoom: %.2f", largeMapZoom))
    else
        minimapZoom = clamp(minimapZoom + delta, zmin, zmax)
        log(string.format("Minimap zoom: %.2f", minimapZoom))
    end
    markOverlayStateDirty(true)
    scheduleMapWork(0, true)
end

registerConfiguredKey("ZoomIn", Config.ZoomInKey, Config.ZoomInModifiers, function()
    adjustZoom(true)
end)

registerConfiguredKey("ZoomOut", Config.ZoomOutKey, Config.ZoomOutModifiers, function()
    adjustZoom(false)
end)

-- Large-map panning (arrow keys by default). Active only while the large map is
-- open AND zoomed past 1.0 (at 1.0 the whole map is visible, nothing to pan to).
local function adjustPan(du, dv)
    if not largeMapOpen then return end
    if largeMapViewU == nil or largeMapViewV == nil then return end
    local zoom = largeMapZoom
    if not zoom or zoom < 1.0 then zoom = 1.0 end
    -- PanStep is a fraction of the *visible* view, so a press moves the same
    -- on-screen distance at any zoom (divide by zoom to get map-UV units).
    local step = ((Config.LargeMap and Config.LargeMap.PanStep) or 0.25) / zoom
    largeMapViewU = clamp(largeMapViewU + du * step, 0.0, 1.0)
    largeMapViewV = clamp(largeMapViewV + dv * step, 0.0, 1.0)
    markOverlayStateDirty(true)
    scheduleMapWork(0, true)
end

registerConfiguredKey("PanUp", Config.PanUpKey, Config.PanUpModifiers, function()
    adjustPan(0, -1)
end)

registerConfiguredKey("PanDown", Config.PanDownKey, Config.PanDownModifiers, function()
    adjustPan(0, 1)
end)

registerConfiguredKey("PanLeft", Config.PanLeftKey, Config.PanLeftModifiers, function()
    adjustPan(-1, 0)
end)

registerConfiguredKey("PanRight", Config.PanRightKey, Config.PanRightModifiers, function()
    adjustPan(1, 0)
end)

safeCall("Register ClientRestart hook", function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
        scheduleMapWork(Config.AttachInitialDelayMs or 250, true)
    end)
end)

RegisterLoadMapPostHook(function()
    if fogSaveDirty then
        safeCall("Fog save on map change", saveFogState)
        fogSaveDirty = false
    end
    stopUpdateLoop()
    cancelAttachAttempt()
    resetOverlay()
    scheduleMapWork(Config.AttachInitialDelayMs or 250, true)
end)

if isFogEnabled() then
    initFogGrid()
    if not loadFogState() then
        log("Fog of war: no save found, starting fresh")
    end
    writeFogTGA()
    log("Fog of war enabled (" .. (Config.FogOfWar.GridWidth or 57) .. "x" .. (Config.FogOfWar.GridHeight or 24) .. ")")
end

scheduleMapWork(Config.AttachInitialDelayMs or 250, true)
log("Loaded. UMG rendering active. M opens/closes the large map, H hides/shows the minimap.")
