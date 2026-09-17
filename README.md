<div align="center">
<h1>ScreenSlanger</h1>
<img
  height="240"
  width="240"
  alt="Screen with a filter applied to it"
  src="./assets/logo-1024.png"
/>

<p>Easy to use utility to apply <a href="https://shader-slang.org/"><code>slang</code></a> shaders to your macOS monitors.</p>

</div>



Useful for applying shaders like [my EINK shader](https://github.com/crutchcorn/eink_slang) or [RetroArch shaders](https://github.com/libretro/slang-shaders) to your monitors in macOS:

![A settings dialog with a slang file applied to 2 of 3 monitors with different parameters.](./assets/usage.png)

# Pre-reqs

- [Homebrew](https://brew.sh/)
- Apple Silicon Mac (M1+) with macOS 26 or later, including macOS 27

# Installation

From a copy of this repository, install or update the shader compilers:

```shell
./scripts/setup-dependencies.sh
```

This installs and upgrades the `glslang` and `spirv-cross` packages in [Brewfile](./Brewfile), then downloads [Slang 2026.18](https://github.com/shader-slang/slang/releases/tag/v2026.18) and checks its SHA-256 checksum. Slang is installed into `~/Library/Application Support/ScreenSlanger/Tools/slang/2026.18`, with a `current` symlink that ScreenSlanger discovers automatically. The full Slang distribution is needed, including its libraries. Existing installations under `~/slang` are preserved.

Build the updated app from this checkout using the instructions below. Packaged builds are available in the [Releases tab](https://github.com/crutchcorn/ScreenSlanger/releases/latest).

Run the setup script again after pulling project updates. Homebrew packages follow their current stable releases; the Slang version and checksums are pinned in the script so a compiler update can be reviewed and tested together with the app. The macOS 27 dependency baseline is:

| Dependency | Version | Purpose |
| --- | --- | --- |
| [Slang](https://github.com/shader-slang/slang/releases/tag/v2026.18) | 2026.18 | Native Slang effects |
| [glslang](https://formulae.brew.sh/formula/glslang) | 16.6.0 | RetroArch GLSL to SPIR-V |
| [SPIRV-Cross](https://formulae.brew.sh/formula/spirv-cross) | 1.4.357.0 | SPIR-V to Metal |

To inspect installed versions:

```shell
brew list --versions glslang spirv-cross
"$HOME/Library/Application Support/ScreenSlanger/Tools/slang/current/bin/slangc" -version
```

For a custom installation, `SLANG_PATH`, `GLSLANG_PATH`, and `SPIRV_CROSS_PATH` may point to the respective executables in the app's environment. `brew install slang` installs the unrelated S-Lang library, not the shader compiler.

# Building from source

Use Xcode 27 with its macOS 27 SDK. Open `ScreenSlanger.xcodeproj`, select the **ScreenSlanger** scheme and **My Mac** destination, then build and run. The app retains macOS 26 as its minimum deployment version. There are no Swift package dependencies to resolve; the shader compilers above are runtime dependencies.

Run the regression checks after updating the compilers:

```shell
./scripts/check-config.sh
./scripts/check-shaders.sh
```

The shader checks require a Mac with access to its Metal GPU. They compile the app's shader adapters, render known pixels through native Slang and RetroArch pipelines, and check texture loading, reloads, and compiler errors. The configuration checks verify display selection and compatibility with existing saved settings. Both scripts build in temporary directories.

# Usage

Open the app's settings and browse to a `.slang` shader or `.slangp` preset.

To test ScreenSlanger, you can use the [waves shader example](./assets/waves.slang) in our project.

Select a shader and at least one display, then click **Activate**. macOS asks for screen-recording access when capture first starts; if needed, enable ScreenSlanger in **System Settings → Privacy & Security → Screen & System Audio Recording** and try again. Settings remain available if capture fails. **Deactivate** stops capture, and **Reload Shader** recompiles the selected shader, including files referenced by a preset.

# Credits

[ScreenShader for the original code implementation](https://github.com/branpk/ScreenShader/)

[ShaderGlass for various `shaderp` code references](https://github.com/mausimus/ShaderGlass)
