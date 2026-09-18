# librashader 0.12.0-screenslanger.1

The unmodified `librashader.h` header is from the official [librashader 0.12.0 macOS release](https://github.com/SnowflakePowered/librashader/releases/tag/librashader-v0.12.0). Its MIT copyright and permission notice are preserved in the header.

The runtime is Copyright SnowflakePowered and contributors, licensed under MPL-2.0. ScreenSlanger builds a modified Metal-only runtime from upstream 0.12.0; the binary is not stored in this repository. ScreenSlanger contributors' modifications are distributed under the same MPL-2.0 license:

- `0001-skip-unused-final-target.patch` avoids allocating an unused final-pass framebuffer when the shader does not require it for feedback.
- `0002-compact-grayscale-luts.patch` stores textures whose red, green, and blue bytes are identical as two-channel gray and alpha textures, with Metal component swizzles preserving the original sampled RGBA values. Color textures retain their original format.

The corresponding source consists of the [upstream tag librashader-v0.12.0](https://github.com/SnowflakePowered/librashader/tree/librashader-v0.12.0) ([source archive](https://github.com/SnowflakePowered/librashader/archive/refs/tags/librashader-v0.12.0.tar.gz)) plus both patches. Application bundles include that exact archive as `librashader-v0.12.0-source.tar.gz`, both patches, `SHA256SUMS`, `BUILD-INFO.txt`, and reproduction instructions in `BUILDING.md` alongside this notice. The upstream archive's SHA-256 is `4bf8cf2489d00848dcabbf2163204093776082da4217d5a5db45e4cbf335cedf`. A copy of the runtime license is in `LICENSE-MPL-2.0.md`. Keep these files together when redistributing the application.

Application builds give the dynamic library a relocatable Mach-O install name and apply the app publisher's code signature. These packaging changes do not modify the implementation beyond the patches described above.

The Swift adapter dynamically loads ABI 2 / API 5 through the official C declarations. Each chain stays on a dedicated OS thread because the upstream Metal runtime is not thread safe. Its shared uniform buffers require at most one outstanding GPU frame per chain; the adapter returns a busy error instead of waiting on the UI thread.
