"Local Windows rendering adaptation; keep the downloaded distribution intact."
BlSpartaD3DCompositorSpaceRenderer compile: 'createCompositor: aSurface
 ^ SkiaCompositorPlatform forD3D: aSurface windowHWND extent: aSurface extent'.
'Loom desktop renderer installed'
