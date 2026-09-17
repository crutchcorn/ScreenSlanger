# librashader 0.12.0

The unmodified `librashader.h` header is from the official [librashader 0.12.0 macOS release](https://github.com/SnowflakePowered/librashader/releases/tag/librashader-v0.12.0). Its MIT copyright and permission notice are preserved in the header.

The runtime is Copyright SnowflakePowered and contributors, licensed under MPL-2.0. The setup script downloads the upstream dynamic library separately; the binary is not stored in this repository. Application builds bundle this runtime after giving its Mach-O install name a relocatable path and applying the app publisher's code signature. Its executable implementation is otherwise unchanged. A copy of the runtime license is in `LICENSE-MPL-2.0.md`.

The corresponding source is available at [tag librashader-v0.12.0](https://github.com/SnowflakePowered/librashader/tree/librashader-v0.12.0) ([source archive](https://github.com/SnowflakePowered/librashader/archive/refs/tags/librashader-v0.12.0.tar.gz)). If distributing the runtime inside an application bundle, include this notice and the MPL license with it.

The Swift adapter dynamically loads ABI 2 / API 5 through the official C declarations. Each chain stays on a dedicated OS thread because the upstream Metal runtime is not thread safe. Its shared uniform buffers require at most one outstanding GPU frame per chain; the adapter returns a busy error instead of waiting on the UI thread.
