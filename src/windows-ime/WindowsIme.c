#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <imm.h>
#include <stdint.h>

// GT's event-loop FFI supports uint64 returns but cannot marshal Win32 BOOL.
// Keep Win32 types and IME context ownership on the native side of this boundary.
__declspec(dllexport) uint64_t loom_ime_set_cursor(
    HWND window, int32_t x, int32_t y, int32_t width, int32_t height) {
    HIMC context = ImmGetContext(window);
    if (!context) return 0;
    RECT area = {x, y, x + width, y + height};
    COMPOSITIONFORM composition = {CFS_POINT, {x, y + height}, area};
    CANDIDATEFORM candidate = {0, CFS_EXCLUDE, {x, y}, area};
    uint64_t result = 1;
    if (ImmSetCompositionWindow(context, &composition)) result |= 2;
    if (ImmSetCandidateWindow(context, &candidate)) result |= 4;
    ImmReleaseContext(window, context);
    return result;
}
