// ScreenSlanger's extension to the pinned runtime. The upstream header is unchanged.
#if defined(__APPLE__) && defined(__OBJC__)
typedef libra_error_t (*PFN_screenslanger_mtl_filter_chain_create_with_compiler)(
    libra_shader_preset_t *preset,
    id<MTLCommandQueue> queue,
    const struct filter_chain_mtl_opt_t *options,
    const char *compiler_path,
    libra_mtl_filter_chain_t *out);
#endif
