import AppKit

class ConfigViewController: NSViewController {
  var config: Config! = nil
  var onConfigUpdate: () -> Void = {}
  var errorMessage: ErrorMessage! = nil
  var parameterState: ShaderParameterState? = nil
  var onParameterChanged: ((String, Float) -> Void)? = nil

  private var stackView: NSStackView! = nil
  private var shaderPathField: NSTextField! = nil
  private var browseButton: NSButton! = nil
  private var activateButton: NSButton! = nil
  private var reloadButton: NSButton! = nil
  private var errorMessageField: NSTextField! = nil
  
  // Parameter controls
  private var parametersSection: NSStackView? = nil
  private var parameterSliders: [String: NSSlider] = [:]
  private var parameterLabels: [String: NSTextField] = [:]
  
  // Monitor selection controls
  private var monitorSection: NSStackView? = nil
  private var monitorCheckboxes: [CGDirectDisplayID: NSButton] = [:]

  override func loadView() {
    self.view = NSView()
    self.view.translatesAutoresizingMaskIntoConstraints = false

    self.stackView = NSStackView()
    self.stackView.orientation = .vertical
    self.stackView.spacing = 16
    self.stackView.alignment = .leading
    self.stackView.translatesAutoresizingMaskIntoConstraints = false
    self.view.addSubview(self.stackView)
    
    // Title
    let titleLabel = NSTextField(labelWithString: "ScreenSlanger")
    titleLabel.font = NSFont.boldSystemFont(ofSize: 18)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    self.stackView.addArrangedSubview(titleLabel)
    
    // Shader file path section
    let shaderPathStack = NSStackView()
    shaderPathStack.orientation = .horizontal
    shaderPathStack.spacing = 8
    shaderPathStack.alignment = .centerY
    shaderPathStack.translatesAutoresizingMaskIntoConstraints = false
    
    let shaderPathLabel = NSTextField(labelWithString: "Shader File:")
    shaderPathLabel.translatesAutoresizingMaskIntoConstraints = false
    shaderPathStack.addArrangedSubview(shaderPathLabel)
    
    self.shaderPathField = NSTextField()
    self.shaderPathField.placeholderString = "Select a .slang or .slangp file..."
    self.shaderPathField.isEditable = false
    self.shaderPathField.focusRingType = .none
    self.shaderPathField.translatesAutoresizingMaskIntoConstraints = false
    self.shaderPathField.stringValue = self.config.shaderPath ?? ""
    shaderPathStack.addArrangedSubview(self.shaderPathField)
    
    self.browseButton = NSButton(title: "Browse...", target: self, action: #selector(self.browseForShader))
    self.browseButton.translatesAutoresizingMaskIntoConstraints = false
    shaderPathStack.addArrangedSubview(self.browseButton)
    
    self.stackView.addArrangedSubview(shaderPathStack)
    
    // Button row
    let buttonStack = NSStackView()
    buttonStack.orientation = .horizontal
    buttonStack.spacing = 12
    buttonStack.alignment = .centerY
    buttonStack.translatesAutoresizingMaskIntoConstraints = false
    
    self.activateButton = NSButton(title: self.getActivateButtonTitle(), target: self, action: #selector(self.toggleActive))
    self.activateButton.translatesAutoresizingMaskIntoConstraints = false
    self.activateButton.bezelStyle = .rounded
    self.activateButton.isEnabled = self.config.hasShaderPath()
    buttonStack.addArrangedSubview(self.activateButton)
    
    self.reloadButton = NSButton(title: "Reload Shader", target: self, action: #selector(self.reloadShader))
    self.reloadButton.translatesAutoresizingMaskIntoConstraints = false
    self.reloadButton.isEnabled = self.config.hasShaderPath()
    buttonStack.addArrangedSubview(self.reloadButton)
    
    self.stackView.addArrangedSubview(buttonStack)
    
    // Monitor selection section
    self.monitorSection = NSStackView()
    self.monitorSection?.orientation = .vertical
    self.monitorSection?.spacing = 8
    self.monitorSection?.alignment = .leading
    self.monitorSection?.translatesAutoresizingMaskIntoConstraints = false
    self.stackView.addArrangedSubview(self.monitorSection!)
    updateMonitorUI()
    
    // Add Slang availability indicator
    if !SlangCompiler.isAvailable {
      let warningLabel = NSTextField(labelWithString: "⚠️ slangc not found - Slang shaders won't compile")
      warningLabel.textColor = .systemOrange
      warningLabel.translatesAutoresizingMaskIntoConstraints = false
      self.stackView.addArrangedSubview(warningLabel)
    }
    
    // Add RetroArch tools availability indicator
    if !RetroArchShaderCompiler.isAvailable {
      let missing = RetroArchShaderCompiler.missingTools.joined(separator: "\n")
      let warningLabel = NSTextField(labelWithString: "⚠️ RetroArch shader tools missing:\n\(missing)")
      warningLabel.textColor = .systemOrange
      warningLabel.translatesAutoresizingMaskIntoConstraints = false
      self.stackView.addArrangedSubview(warningLabel)
    }
    
    // Shader parameters section (populated dynamically)
    self.parametersSection = NSStackView()
    self.parametersSection?.orientation = .vertical
    self.parametersSection?.spacing = 8
    self.parametersSection?.alignment = .leading
    self.parametersSection?.translatesAutoresizingMaskIntoConstraints = false
    self.stackView.addArrangedSubview(self.parametersSection!)
    
    // Error message field
    self.errorMessageField = NSTextField()
    self.errorMessageField.isEditable = false
    self.errorMessageField.drawsBackground = false
    self.errorMessageField.font = NSFont.monospacedSystemFont(
      ofSize: NSFont.systemFontSize, weight: .regular)
    self.errorMessageField.textColor = .red
    self.errorMessageField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    self.errorMessageField.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    self.errorMessageField.translatesAutoresizingMaskIntoConstraints = false
    self.stackView.addArrangedSubview(self.errorMessageField)

    self.errorMessage.onMessageChanged = {
      self.errorMessageField.stringValue = self.errorMessage.get() ?? ""
      self.errorMessageField.isHidden = self.errorMessage.get() == nil
    }
    self.errorMessage.onMessageChanged?()

    NSLayoutConstraint.activate([
      self.stackView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20),
      self.stackView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -20),
      self.stackView.topAnchor.constraint(equalTo: self.view.topAnchor, constant: 20),
      
      self.shaderPathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
    ])
  }
  
  private func getActivateButtonTitle() -> String {
    return self.config.active ? "Deactivate" : "Activate"
  }
  
  @objc func toggleActive() {
    self.config.toggleActive()
    self.activateButton.title = self.getActivateButtonTitle()
    self.onConfigUpdate()
  }
  
  @objc func browseForShader() {
    let openPanel = NSOpenPanel()
    openPanel.title = "Select Shader File"
    // Allow both .slang shader files and .slangp preset files
    openPanel.allowedContentTypes = [
      .init(filenameExtension: "slang")!,
      .init(filenameExtension: "slangp")!
    ]
    openPanel.allowsMultipleSelection = false
    openPanel.canChooseDirectories = false
    openPanel.canChooseFiles = true
    
    openPanel.begin { [weak self] result in
      guard let self = self else { return }
      if result == .OK, let url = openPanel.url {
        let path = url.path
        self.config.shaderPath = path
        self.shaderPathField.stringValue = path
        self.activateButton.isEnabled = true
        self.reloadButton.isEnabled = true
        
        self.onConfigUpdate()
      }
    }
  }
  
  @objc func reloadShader() {
    // Force re-read of the shader file by triggering an update
    self.onConfigUpdate()
  }
  
  func refreshUI() {
    self.activateButton.title = self.getActivateButtonTitle()
    self.activateButton.isEnabled = self.config.hasShaderPath()
    self.updateMonitorUI()
    self.updateParameterUI()
  }
  
  /// Update the monitor selection UI
  func updateMonitorUI() {
    // Remove existing monitor controls
    self.monitorSection?.arrangedSubviews.forEach { $0.removeFromSuperview() }
    self.monitorCheckboxes.removeAll()
    
    // Add header
    let headerLabel = NSTextField(labelWithString: "Displays")
    headerLabel.font = NSFont.boldSystemFont(ofSize: 14)
    headerLabel.translatesAutoresizingMaskIntoConstraints = false
    self.monitorSection?.addArrangedSubview(headerLabel)
    
    // Add a checkbox for each connected display
    for (index, screen) in NSScreen.screens.enumerated() {
      let displayID = getDisplayID(for: screen)
      let isEnabled = config.isDisplayEnabled(displayID)
      
      // Get display name
      let displayName = screen.localizedName
      let resolution = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
      let isMain = screen == NSScreen.main ? " (Main)" : ""
      let label = "Display \(index + 1): \(displayName) - \(resolution)\(isMain)"
      
      let checkbox = NSButton(checkboxWithTitle: label, target: self, action: #selector(monitorCheckboxChanged(_:)))
      checkbox.state = isEnabled ? .on : .off
      checkbox.tag = Int(displayID)
      checkbox.translatesAutoresizingMaskIntoConstraints = false
      
      self.monitorCheckboxes[displayID] = checkbox
      self.monitorSection?.addArrangedSubview(checkbox)
    }
  }
  
  /// Get the CGDirectDisplayID for a screen
  private func getDisplayID(for screen: NSScreen) -> CGDirectDisplayID {
    let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
    return CGDirectDisplayID(screenNumber.uint32Value)
  }
  
  @objc func monitorCheckboxChanged(_ sender: NSButton) {
    let displayID = CGDirectDisplayID(sender.tag)
    config.toggleDisplay(displayID)
    
    // Update all checkbox states to reflect current config
    for (id, checkbox) in monitorCheckboxes {
      checkbox.state = config.isDisplayEnabled(id) ? .on : .off
    }
    
    onConfigUpdate()
  }
  
  /// Update parameter sliders when shader changes
  func updateParameterUI() {
    // Remove existing parameter controls
    self.parametersSection?.arrangedSubviews.forEach { $0.removeFromSuperview() }
    self.parameterSliders.removeAll()
    self.parameterLabels.removeAll()
    
    guard let state = self.parameterState, !state.parameters.isEmpty else {
      return
    }
    
    // Add header
    let headerLabel = NSTextField(labelWithString: "Shader Parameters")
    headerLabel.font = NSFont.boldSystemFont(ofSize: 14)
    headerLabel.translatesAutoresizingMaskIntoConstraints = false
    self.parametersSection?.addArrangedSubview(headerLabel)
    
    // Add a slider for each parameter
    for param in state.parameters {
      let paramStack = NSStackView()
      paramStack.orientation = .horizontal
      paramStack.spacing = 8
      paramStack.alignment = .centerY
      paramStack.translatesAutoresizingMaskIntoConstraints = false
      
      // Parameter name label
      let nameLabel = NSTextField(labelWithString: param.description)
      nameLabel.translatesAutoresizingMaskIntoConstraints = false
      nameLabel.toolTip = param.name
      paramStack.addArrangedSubview(nameLabel)
      
      // Slider
      let slider = NSSlider(value: Double(state.getValue(for: param.name)),
                            minValue: Double(param.minValue),
                            maxValue: Double(param.maxValue),
                            target: self,
                            action: #selector(parameterSliderChanged(_:)))
      slider.translatesAutoresizingMaskIntoConstraints = false
      slider.identifier = NSUserInterfaceItemIdentifier(param.name)
      slider.isContinuous = true
      paramStack.addArrangedSubview(slider)
      
      // Value label
      let valueLabel = NSTextField(labelWithString: String(format: "%.2f", state.getValue(for: param.name)))
      valueLabel.translatesAutoresizingMaskIntoConstraints = false
      valueLabel.isEditable = false
      paramStack.addArrangedSubview(valueLabel)
      
      // Reset button
      let resetButton = NSButton(title: "↺", target: self, action: #selector(resetParameter(_:)))
      resetButton.identifier = NSUserInterfaceItemIdentifier(param.name)
      resetButton.toolTip = "Reset to default (\(param.defaultValue))"
      resetButton.bezelStyle = .inline
      paramStack.addArrangedSubview(resetButton)
      
      self.parameterSliders[param.name] = slider
      self.parameterLabels[param.name] = valueLabel
      
      self.parametersSection?.addArrangedSubview(paramStack)
      
      // Add width constraints
      NSLayoutConstraint.activate([
        nameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        slider.widthAnchor.constraint(equalToConstant: 200),
        valueLabel.widthAnchor.constraint(equalToConstant: 50)
      ])
    }
    
    // Add "Reset All" button
    let resetAllButton = NSButton(title: "Reset All Parameters", target: self, action: #selector(resetAllParameters))
    resetAllButton.translatesAutoresizingMaskIntoConstraints = false
    self.parametersSection?.addArrangedSubview(resetAllButton)
  }
  
  @objc func parameterSliderChanged(_ sender: NSSlider) {
    guard let paramName = sender.identifier?.rawValue else { return }
    let value = Float(sender.doubleValue)
    
    // Update the value label
    if let label = parameterLabels[paramName] {
      label.stringValue = String(format: "%.2f", value)
    }
    
    // Update the parameter state
    parameterState?.setValue(value, for: paramName)
    
    // Save to config
    config.setParameterValue(name: paramName, value: value)
    
    // Notify the renderer
    onParameterChanged?(paramName, value)
  }
  
  @objc func resetParameter(_ sender: NSButton) {
    guard let paramName = sender.identifier?.rawValue,
          let param = parameterState?.parameters.first(where: { $0.name == paramName }) else { return }
    
    let defaultValue = param.defaultValue
    parameterState?.setValue(defaultValue, for: paramName)
    
    if let slider = parameterSliders[paramName] {
      slider.doubleValue = Double(defaultValue)
    }
    if let label = parameterLabels[paramName] {
      label.stringValue = String(format: "%.2f", defaultValue)
    }
    
    config.setParameterValue(name: paramName, value: defaultValue)
    onParameterChanged?(paramName, defaultValue)
  }
  
  @objc func resetAllParameters() {
    guard let state = parameterState else { return }
    
    for param in state.parameters {
      let defaultValue = param.defaultValue
      state.setValue(defaultValue, for: param.name)
      
      if let slider = parameterSliders[param.name] {
        slider.doubleValue = Double(defaultValue)
      }
      if let label = parameterLabels[param.name] {
        label.stringValue = String(format: "%.2f", defaultValue)
      }
      
      config.setParameterValue(name: param.name, value: defaultValue)
      onParameterChanged?(param.name, defaultValue)
    }
  }
}

class ConfigWindowController: NSWindowController {
  var config: Config! = nil
  var errorMessage: ErrorMessage! = nil
  var onConfigUpdate: () -> Void = {}
  var parameterState: ShaderParameterState? = nil
  var onParameterChanged: ((String, Float) -> Void)? = nil

  private var configViewController: ConfigViewController! = ConfigViewController()

  func createUI() {
    guard let window = self.window else { return }

    window.title = "ScreenSlanger Settings"

    self.configViewController.config = self.config
    self.configViewController.onConfigUpdate = self.onConfigUpdate
    self.configViewController.errorMessage = self.errorMessage
    self.configViewController.parameterState = self.parameterState
    self.configViewController.onParameterChanged = self.onParameterChanged
    window.contentView?.addSubview(self.configViewController.view)

    NSLayoutConstraint.activate([
      self.configViewController.view.leadingAnchor.constraint(
        equalTo: window.contentView!.leadingAnchor),
      self.configViewController.view.trailingAnchor.constraint(
        equalTo: window.contentView!.trailingAnchor),
      self.configViewController.view.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
      self.configViewController.view.bottomAnchor.constraint(
        equalTo: window.contentView!.bottomAnchor),
    ])
  }

  func refreshActiveEffects() {
    self.configViewController.refreshUI()
  }
  
  func updateParameterState(_ state: ShaderParameterState?) {
    self.parameterState = state
    self.configViewController.parameterState = state
    self.configViewController.updateParameterUI()
  }
}
