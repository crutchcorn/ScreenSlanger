import AppKit
import CoreGraphics

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  private var config: Config!
  private var configChanged: Bool = false
  private var metrics: Metrics = Metrics()
  private var errorMessage: ErrorMessage = ErrorMessage()
  private var overlayControllers: [CGDirectDisplayID: OverlayController] = [:]
  private var statusItem: NSStatusItem!
  private var configWindowController: ConfigWindowController?
  private var configTimer: Timer?
  private var metricsTimer: Timer?
  private var shaderLoadTask: Task<Void, Never>?
  private var shaderLoadGeneration: UInt64 = 0
  private var requestedShader: ShaderSelection?
  private var shaderReady = false

  private struct ShaderSelection: Equatable {
    let path: String?
    let displayIDs: [UInt32]
    let active: Bool
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // ScreenCaptureKit requests permission when an effect is activated. Keep
    // Settings available if permission is denied so the user can retry later.
    self.config = Config.load()
    let configTimer = Timer.scheduledTimer(
      timeInterval: 1.0, target: self, selector: #selector(saveConfigIfNeeded),
      userInfo: nil, repeats: true)
    RunLoop.current.add(configTimer, forMode: .common)
    self.configTimer = configTimer

    let metricsTimer = Timer.scheduledTimer(
      timeInterval: 10.0, target: self, selector: #selector(updateMetrics),
      userInfo: nil, repeats: true)
    RunLoop.current.add(metricsTimer, forMode: .common)
    self.metricsTimer = metricsTimer

    NotificationCenter.default.addObserver(
      self, selector: #selector(displaysChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(displaysChanged), name: NSWorkspace.didWakeNotification, object: nil)

    setupMenuBar()
    createMenuBarIcon()

    createOverlayControllers()

    self.refreshConfig()
    self.openConfigWindow()
  }

  @objc private func saveConfigIfNeeded() {
    if self.configChanged && self.config.save() {
      self.configChanged = false
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    configTimer?.invalidate()
    metricsTimer?.invalidate()
    saveConfigIfNeeded()
    shaderLoadTask?.cancel()
    SharedMetalResources.shared.clear()
    for controller in overlayControllers.values { controller.cleanup() }
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  @objc private func displaysChanged(_ notification: Notification) {
    let waking = notification.name == NSWorkspace.didWakeNotification
    if waking {
      for controller in overlayControllers.values { controller.cleanup() }
      overlayControllers.removeAll()
    }
    refreshConfig(forceReload: waking)
  }

  @objc private func updateMetrics() {
    self.metrics.updateStats()
    self.metrics.printStats()
  }
  
  /// Create overlay controllers for all enabled screens
  private func createOverlayControllers() {
    updateOverlayControllers()
  }
  
  /// Update overlay controllers - only add/remove what changed
  @discardableResult
  private func updateOverlayControllers() -> Bool {
    var controllersChanged = false
    // Get current set of enabled display IDs
    var enabledDisplayIDs = Set<CGDirectDisplayID>()
    var screensByID: [CGDirectDisplayID: NSScreen] = [:]
    
    for screen in NSScreen.screens {
      let displayID = getDisplayID(for: screen)
      if config.isDisplayEnabled(displayID) {
        enabledDisplayIDs.insert(displayID)
        screensByID[displayID] = screen
      }
    }
    
    // Remove controllers for displays that are no longer enabled
    let existingIDs = Set(overlayControllers.keys)
    for displayID in existingIDs {
      if !enabledDisplayIDs.contains(displayID)
        || screensByID[displayID].map({ !overlayControllers[displayID]!.matchesDisplay($0) }) == true {
        // Explicitly cleanup before removing
        overlayControllers[displayID]?.cleanup()
        overlayControllers.removeValue(forKey: displayID)
        controllersChanged = true
      }
    }
    
    // Add controllers for newly enabled displays
    for displayID in enabledDisplayIDs {
      if overlayControllers[displayID] == nil, let screen = screensByID[displayID] {
        let controller = OverlayController(
          config: self.config,
          metrics: self.metrics,
          errorMessage: self.errorMessage,
          screen: screen
        )
        controller.onCaptureStopped = { [weak self] in
          guard let self = self else { return }
          self.config.active = false
          self.refreshConfig()
        }
        overlayControllers[displayID] = controller
        controllersChanged = true
      }
    }
    return controllersChanged
  }
  
  /// Get the CGDirectDisplayID for a screen
  private func getDisplayID(for screen: NSScreen) -> CGDirectDisplayID {
    let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
    return CGDirectDisplayID(screenNumber.uint32Value)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    self.openConfigWindow()
    return true
  }

  private func refreshConfig(forceReload: Bool = false) {
    self.statusItem.button?.image = self.getMenuBarIcon()
    let controllersChanged = updateOverlayControllers()
    self.configChanged = true

    let selection = ShaderSelection(
      path: config.shaderPath, displayIDs: overlayControllers.keys.sorted(), active: config.active)
    // Recreated renderers restart FrameCount, so their feedback/history chains
    // must restart too, even if display IDs and the shader path did not change.
    if selection != requestedShader || forceReload || controllersChanged {
      requestedShader = selection
      shaderLoadGeneration &+= 1
      let generation = shaderLoadGeneration
      shaderLoadTask?.cancel()
      shaderLoadTask = nil
      shaderReady = false
      SharedMetalResources.shared.clear()
      refreshOverlayState()

      guard selection.active, let path = selection.path, !path.isEmpty,
        !selection.displayIDs.isEmpty else { return }
      errorMessage.clear()
      let request = ShaderLoadRequest(
        source: nil, url: URL(fileURLWithPath: path), displayIDs: selection.displayIDs)
      shaderLoadTask = Task { [weak self] in
        guard let self else { return }
        do {
          try await SharedMetalResources.shared.loadEffect(request)
          guard !Task.isCancelled, self.shaderLoadGeneration == generation else { return }
          self.shaderLoadTask = nil
          self.shaderReady = true
          self.config.applyStoredParameters(to: SharedMetalResources.shared.parameterState)
          self.errorMessage.clear()
          self.refreshOverlayState()
        } catch is CancellationError {
          // A newer selection or deactivation owns the current UI state.
        } catch {
          guard !Task.isCancelled, self.shaderLoadGeneration == generation else { return }
          self.shaderLoadTask = nil
          self.shaderReady = false
          self.config.active = false
          self.errorMessage.set(error.localizedDescription)
          self.refreshConfig()
        }
      }
    } else {
      // Frame-rate and idle-animation changes only reconfigure drawing/capture.
      refreshOverlayState()
    }
  }

  private func refreshOverlayState() {
    for controller in overlayControllers.values {
      controller.refreshConfig(ready: shaderReady)
    }
    self.configWindowController?.refreshActiveEffects()
    self.updateParameterUI()
  }

  private func setupMenuBar() {
    let mainMenu = NSMenu()

    let appMenu = NSMenuItem()
    mainMenu.addItem(appMenu)
    let appSubMenu = NSMenu()
    appMenu.submenu = appSubMenu

    let settingsItem = NSMenuItem(
      title: "Settings", action: #selector(self.openConfigWindow), keyEquivalent: ",")
    settingsItem.target = self
    appSubMenu.addItem(settingsItem)
    
    appSubMenu.addItem(NSMenuItem.separator())
    appSubMenu.addItem(
      NSMenuItem(
        title: "Quit ScreenSlanger", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))

    let editMenu = NSMenuItem()
    mainMenu.addItem(editMenu)
    let editSubMenu = NSMenu(title: "Edit")
    editMenu.submenu = editSubMenu

    editSubMenu.addItem(
      NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
    editSubMenu.addItem(
      NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
    editSubMenu.addItem(NSMenuItem.separator())
    editSubMenu.addItem(
      NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    editSubMenu.addItem(
      NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editSubMenu.addItem(
      NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editSubMenu.addItem(
      NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

    NSApp.mainMenu = mainMenu
  }

  private func createMenuBarIcon() {
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    if let button = self.statusItem.button {
      button.image = self.getMenuBarIcon()
      button.action = #selector(self.toggleEffect)
      button.target = self
    }
  }

  private func getMenuBarIcon() -> NSImage {
    let active = self.config.active
    let systemSymbolName = active ? "paintbrush.fill" : "paintbrush"
    return NSImage(
      systemSymbolName: systemSymbolName, accessibilityDescription: "ScreenSlanger")!
  }

  @objc private func toggleEffect() {
    self.config.toggleActive()
    self.refreshConfig()
  }

  @objc private func openConfigWindow() {
    if self.configWindowController != nil {
      self.configWindowController!.window?.makeKeyAndOrderFront(nil)
      return
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.center()

    self.configWindowController = ConfigWindowController(window: window)
    self.configWindowController!.config = self.config
    self.configWindowController!.onConfigUpdate = { [weak self] in
      self?.refreshConfig()
    }
    self.configWindowController!.onReloadShader = { [weak self] in
      self?.refreshConfig(forceReload: true)
    }
    self.configWindowController!.errorMessage = self.errorMessage
    self.configWindowController!.parameterState = self.getFirstParameterState()
    self.configWindowController!.onParameterChanged = { [weak self] name, value in
      self?.setParameterValueOnAllControllers(name: name, value: value)
      self?.configChanged = true
    }
    self.configWindowController!.createUI()

    window.makeKeyAndOrderFront(nil)
  }
  
  /// Get parameter state from the first overlay controller
  private func getFirstParameterState() -> ShaderParameterState? {
    return overlayControllers.values.first?.getParameterState()
  }
  
  /// Set parameter value on all overlay controllers
  private func setParameterValueOnAllControllers(name: String, value: Float) {
    for controller in overlayControllers.values {
      controller.setParameterValue(name: name, value: value)
    }
  }
  
  private func updateParameterUI() {
    self.configWindowController?.updateParameterState(self.getFirstParameterState())
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
