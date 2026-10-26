// d3d9tri.exe: a Direct3D 9 smoke test (DXVK's d3d9 -> Vulkan). Fixed-function triangle, no shaders, N frames
// (default 300, arg 1), centre pixel read back from the last frame. Exit code 0 only if it is the triangle colour.
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include "out.h"
#include <stdlib.h>

struct vtx { float x, y, z, rhw; DWORD color; };

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    return DefWindowProcW(h, m, w, l);
}

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 300;
    const int W = 640, H = 480;
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"d3d9tri";
    RegisterClassW(&wc);
    HWND hwnd = CreateWindowW(L"d3d9tri", L"d3d9tri", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 0, 0, W, H, NULL, NULL,
                              wc.hInstance, NULL);
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) {
        out("d3d9tri FAIL Direct3DCreate9\n");
        return 2;
    }
    D3DADAPTER_IDENTIFIER9 id;
    if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, 0, 0, &id)))
        out("d3d9tri adapter: %s\n", id.Description);
    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = W;
    pp.BackBufferHeight = H;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
    IDirect3DDevice9 *dev;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, 0, D3DDEVTYPE_HAL, hwnd, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
    if (FAILED(hr)) {
        out("d3d9tri FAIL CreateDevice hr=0x%08lx\n", (unsigned long)hr);
        return 2;
    }
    struct vtx v[3] = {
        {W / 2.0f, H * 0.1f, 0.5f, 1, 0xff00ff80},
        {W * 0.9f, H * 0.9f, 0.5f, 1, 0xff00ff80},
        {W * 0.1f, H * 0.9f, 0.5f, 1, 0xff00ff80},
    };
    IDirect3DSurface9 *sysmem;
    IDirect3DDevice9_CreateOffscreenPlainSurface(dev, W, H, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &sysmem, NULL);
    LARGE_INTEGER f, t0, t1;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&t0);
    DWORD px = 0;
    for (int i = 0; i < frames; i++) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE))
            DispatchMessageW(&msg);
        IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, 0xff102040, 1.0f, 0);
        IDirect3DDevice9_BeginScene(dev);
        IDirect3DDevice9_SetFVF(dev, D3DFVF_XYZRHW | D3DFVF_DIFFUSE);
        IDirect3DDevice9_DrawPrimitiveUP(dev, D3DPT_TRIANGLELIST, 1, v, sizeof v[0]);
        IDirect3DDevice9_EndScene(dev);
        if (i == frames - 1) {
            IDirect3DSurface9 *bb;
            IDirect3DDevice9_GetBackBuffer(dev, 0, 0, D3DBACKBUFFER_TYPE_MONO, &bb);
            D3DLOCKED_RECT lr;
            if (SUCCEEDED(IDirect3DDevice9_GetRenderTargetData(dev, bb, sysmem)) &&
                SUCCEEDED(IDirect3DSurface9_LockRect(sysmem, &lr, NULL, D3DLOCK_READONLY))) {
                px = *(DWORD *)((char *)lr.pBits + (H / 2) * lr.Pitch + (W / 2) * 4);
                IDirect3DSurface9_UnlockRect(sysmem);
            }
            IDirect3DSurface9_Release(bb);
        }
        IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL);
    }
    QueryPerformanceCounter(&t1);
    double s = (double)(t1.QuadPart - t0.QuadPart) / f.QuadPart;
    unsigned r = (px >> 16) & 0xff, g = (px >> 8) & 0xff, b = px & 0xff;
    out("d3d9tri %d frames in %.2f s = %.1f fps, centre pixel rgb(%u,%u,%u)\n", frames, s, frames / s, r, g, b);
    int ok = r < 16 && g > 240 && b > 110 && b < 145;
    out("d3d9tri %s\n", ok ? "PASS" : "FAIL wrong pixel");
    return ok ? 0 : 1;
}
