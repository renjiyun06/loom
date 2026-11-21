#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <imm.h>
#include <stdint.h>
#include <stdio.h>

typedef uint64_t (*LoomSetImeCursor)(HWND, int32_t, int32_t, int32_t, int32_t);
int wmain(int argc, wchar_t **argv) {
    if (argc != 2) return 1;
    HMODULE module=LoadLibraryW(argv[1]);
    if (!module) return 2;
    LoomSetImeCursor setCursor=(LoomSetImeCursor)(void*)GetProcAddress(module,"loom_ime_set_cursor");
    if (!setCursor) return 3;
    HWND window=CreateWindowExW(0,L"STATIC",L"IME native test",WS_POPUP,
        0,0,800,600,NULL,NULL,GetModuleHandleW(NULL),NULL);
    if (!window) return 4;
    HIMC context=ImmCreateContext();
    HIMC previous=ImmAssociateContext(window,context);
    int positions[][4]={{31,400,2,24},{280,190,3,28}};
    int okay=1;
    for (int i=0;i<2;i++) {
        int *p=positions[i];
        COMPOSITIONFORM composition={0};
        CANDIDATEFORM candidate={0};
        uint64_t flags=setCursor(window,p[0],p[1],p[2],p[3]);
        okay &= flags==7 && ImmGetCompositionWindow(context,&composition)
            && ImmGetCandidateWindow(context,0,&candidate);
        okay &= composition.dwStyle==CFS_POINT
            && composition.ptCurrentPos.x==p[0] && composition.ptCurrentPos.y==p[1]+p[3]
            && candidate.dwStyle==CFS_EXCLUDE
            && candidate.rcArea.left==p[0] && candidate.rcArea.top==p[1]
            && candidate.rcArea.right==p[0]+p[2] && candidate.rcArea.bottom==p[1]+p[3];
    }
    ImmAssociateContext(window,previous);
    ImmDestroyContext(context);DestroyWindow(window);FreeLibrary(module);
    printf("{\"nativeImePlacement\":%s,\"positionsChecked\":2}\n",okay?"true":"false");
    return okay?0:5;
}
