import AppKit

class EffectViewController: NSViewController, NSTextFieldDelegate {
  var effects: Effects! = nil
  var effect: UUID! = nil
  var onUpdate: () -> Void = {}
  var onDelete: () -> Void = {}

  private var stackView: NSStackView! = nil
  private var nameField: NSTextField! = nil
  private var activeButton: NSButton! = nil
  private var languageLabel: NSTextField! = nil
  private var deleteButton: NSButton! = nil
  private var shaderPathLabel: NSTextField! = nil
  private var shaderPathField: NSTextField! = nil
  private var browseButton: NSButton! = nil
  private var reloadButton: NSButton! = nil

  override func loadView() {
    self.view = NSView()
    self.view.translatesAutoresizingMaskIntoConstraints = false

    self.stackView = NSStackView()
    self.stackView.orientation = .vertical
    self.stackView.spacing = 10
    self.stackView.alignment = .leading
    self.stackView.translatesAutoresizingMaskIntoConstraints = false
    self.view.addSubview(self.stackView)

    self.nameField = NSTextField()
    self.nameField.placeholderString = "Effect Name"
    self.nameField.focusRingType = .none
    self.nameField.delegate = self
    self.nameField.translatesAutoresizingMaskIntoConstraints = false
    self.nameField.stringValue = self.effects.getName(effect: self.effect)
    self.stackView.addArrangedSubview(self.nameField)

    self.activeButton = NSButton(
      checkboxWithTitle: "Active (only one effect can be active at a time)",
      target: self,
      action: #selector(self.toggleActive))
    self.activeButton.translatesAutoresizingMaskIntoConstraints = false
    self.activeButton.state = self.effects.isActive(effect: self.effect) ? .on : .off
    self.stackView.addArrangedSubview(self.activeButton)
    
    // Shader file path section
    let shaderPathStack = NSStackView()
    shaderPathStack.orientation = .horizontal
    shaderPathStack.spacing = 8
    shaderPathStack.alignment = .centerY
    shaderPathStack.translatesAutoresizingMaskIntoConstraints = false
    
    self.shaderPathLabel = NSTextField(labelWithString: "Shader File:")
    self.shaderPathLabel.translatesAutoresizingMaskIntoConstraints = false
    shaderPathStack.addArrangedSubview(self.shaderPathLabel)
    
    self.shaderPathField = NSTextField()
    self.shaderPathField.placeholderString = "Select a .slang or .metal file..."
    self.shaderPathField.isEditable = false
    self.shaderPathField.focusRingType = .none
    self.shaderPathField.translatesAutoresizingMaskIntoConstraints = false
    self.shaderPathField.stringValue = self.effects.getShaderPath(effect: self.effect) ?? ""
    shaderPathStack.addArrangedSubview(self.shaderPathField)
    
    self.browseButton = NSButton(title: "Browse...", target: self, action: #selector(self.browseForShader))
    self.browseButton.translatesAutoresizingMaskIntoConstraints = false
    shaderPathStack.addArrangedSubview(self.browseButton)
    
    self.reloadButton = NSButton(title: "Reload", target: self, action: #selector(self.reloadShader))
    self.reloadButton.translatesAutoresizingMaskIntoConstraints = false
    self.reloadButton.isEnabled = self.effects.hasShaderPath(effect: self.effect)
    shaderPathStack.addArrangedSubview(self.reloadButton)
    
    self.stackView.addArrangedSubview(shaderPathStack)
    
    // Show current shader language
    self.languageLabel = NSTextField(labelWithString: "Language: \(self.effects.getLanguage(effect: self.effect).displayName)")
    self.languageLabel.translatesAutoresizingMaskIntoConstraints = false
    self.stackView.addArrangedSubview(self.languageLabel)
    
    // Add Slang availability indicator
    if !SlangCompiler.isAvailable {
      let warningLabel = NSTextField(labelWithString: "⚠️ slangc not found - Slang shaders won't compile")
      warningLabel.textColor = .systemOrange
      warningLabel.translatesAutoresizingMaskIntoConstraints = false
      self.stackView.addArrangedSubview(warningLabel)
    }

    self.deleteButton = NSButton(
      title: "Delete effect",
      target: self,
      action: #selector(self.deleteEffect))
    self.deleteButton.translatesAutoresizingMaskIntoConstraints = false
    self.stackView.addArrangedSubview(self.deleteButton)

    NSLayoutConstraint.activate([
      self.stackView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 10),
      self.stackView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -10),
      self.stackView.topAnchor.constraint(equalTo: self.view.topAnchor, constant: 10),
      self.stackView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor, constant: -10),
      
      self.shaderPathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
    ])
  }

  @objc func toggleActive() {
    self.effects.toggleActive(effect: self.effect)
    self.onUpdate()
  }

  @objc func deleteEffect() {
    self.effects.delete(effect: self.effect)
    self.onDelete()
  }
  
  @objc func browseForShader() {
    let openPanel = NSOpenPanel()
    openPanel.title = "Select Shader File"
    openPanel.allowedContentTypes = [.init(filenameExtension: "slang")!, .init(filenameExtension: "metal")!]
    openPanel.allowsMultipleSelection = false
    openPanel.canChooseDirectories = false
    openPanel.canChooseFiles = true
    
    openPanel.begin { [weak self] result in
      guard let self = self else { return }
      if result == .OK, let url = openPanel.url {
        let path = url.path
        self.effects.setShaderPath(effect: self.effect, path: path)
        self.shaderPathField.stringValue = path
        self.reloadButton.isEnabled = true
        
        // Update language label based on file extension
        let language = self.effects.getLanguage(effect: self.effect)
        self.languageLabel.stringValue = "Language: \(language.displayName)"
        
        self.onUpdate()
      }
    }
  }
  
  @objc func reloadShader() {
    // Force re-read of the shader file by triggering an update
    self.onUpdate()
  }

  func controlTextDidChange(_ obj: Notification) {
    let newName = self.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !newName.isEmpty {
      self.effects.setName(effect: self.effect, newName: self.nameField.stringValue)
      self.onUpdate()
    }
  }

  func refreshActiveCheckbox() {
    self.activeButton.state = self.effects.isActive(effect: self.effect) ? .on : .off
  }
}
