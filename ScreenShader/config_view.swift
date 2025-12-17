import AppKit

class ConfigViewController: NSViewController {
  var config: Config! = nil
  var onConfigUpdate: () -> Void = {}
  var errorMessage: ErrorMessage! = nil

  private var stackView: NSStackView! = nil
  private var shaderPathField: NSTextField! = nil
  private var browseButton: NSButton! = nil
  private var activateButton: NSButton! = nil
  private var reloadButton: NSButton! = nil
  private var errorMessageField: NSTextField! = nil

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
    let titleLabel = NSTextField(labelWithString: "ScreenShader")
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
    self.shaderPathField.placeholderString = "Select a .slang file..."
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
    
    // Add Slang availability indicator
    if !SlangCompiler.isAvailable {
      let warningLabel = NSTextField(labelWithString: "⚠️ slangc not found - Slang shaders won't compile")
      warningLabel.textColor = .systemOrange
      warningLabel.translatesAutoresizingMaskIntoConstraints = false
      self.stackView.addArrangedSubview(warningLabel)
    }
    
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
    openPanel.allowedContentTypes = [.init(filenameExtension: "slang")!]
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
  }
}

class ConfigWindowController: NSWindowController {
  var config: Config! = nil
  var errorMessage: ErrorMessage! = nil
  var onConfigUpdate: () -> Void = {}

  private var configViewController: ConfigViewController! = ConfigViewController()

  func createUI() {
    guard let window = self.window else { return }

    window.title = "ScreenShader Settings"

    self.configViewController.config = self.config
    self.configViewController.onConfigUpdate = self.onConfigUpdate
    self.configViewController.errorMessage = self.errorMessage
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
}
