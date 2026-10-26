// d3d11tri.exe: a Direct3D 11 smoke test for the phone's Proton path (DXVK -> Vulkan -> Turnip/lavapipe).
// Opens a window, draws a coloured triangle for N frames (default 300, arg 1), reads the centre pixel of the
// last frame back and prints it with the frame rate. Exit code 0 only if the pixel is the triangle's colour.
//   d3d11tri.exe [frames]
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include "out.h"
#include <stdlib.h>

static const char shader[] =
    "float4 vs(uint id : SV_VertexID) : SV_Position {\n"
    "  float2 p[3] = { float2(0, 0.8), float2(0.8, -0.8), float2(-0.8, -0.8) };\n"
    "  return float4(p[id], 0, 1); }\n"
    "float4 ps() : SV_Target { return float4(1.0, 0.5, 0.0, 1.0); }\n";

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_DESTROY)
        PostQuitMessage(0);
    return DefWindowProcW(h, m, w, l);
}

static int fail(const char *what, HRESULT hr)
{
    out("d3d11tri FAIL %s hr=0x%08lx\n", what, (unsigned long)hr);
    return 2;
}

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 300;
    const int W = 640, H = 480;
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"d3d11tri";
    RegisterClassW(&wc);
    HWND hwnd = CreateWindowW(L"d3d11tri", L"d3d11tri", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 0, 0, W, H, NULL, NULL,
                              wc.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 2;
    sd.BufferDesc.Width = W;
    sd.BufferDesc.Height = H;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    IDXGISwapChain *sc;
    ID3D11Device *dev;
    ID3D11DeviceContext *ctx;
    D3D_FEATURE_LEVEL fl;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                               &sd, &sc, &dev, &fl, &ctx);
    if (FAILED(hr))
        return fail("D3D11CreateDeviceAndSwapChain", hr);
    out("d3d11tri device ok, feature level 0x%x\n", fl);

    ID3DBlob *vsb, *psb, *err = NULL;
    if (FAILED(hr = D3DCompile(shader, sizeof shader - 1, NULL, NULL, NULL, "vs", "vs_4_0", 0, 0, &vsb, &err)))
        return fail("D3DCompile vs", hr);
    if (FAILED(hr = D3DCompile(shader, sizeof shader - 1, NULL, NULL, NULL, "ps", "ps_4_0", 0, 0, &psb, &err)))
        return fail("D3DCompile ps", hr);
    ID3D11VertexShader *vs;
    ID3D11PixelShader *ps;
    ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(vsb), ID3D10Blob_GetBufferSize(vsb), NULL, &vs);
    ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(psb), ID3D10Blob_GetBufferSize(psb), NULL, &ps);

    ID3D11Texture2D *bb;
    ID3D11RenderTargetView *rtv;
    IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb);
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv);
    D3D11_VIEWPORT vp = {0, 0, W, H, 0, 1};
    const float clear[4] = {0.0f, 0.2f, 0.4f, 1.0f};

    // Staging copy of the last frame, for the readback check.
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc(bb, &td);
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    td.MiscFlags = 0;
    ID3D11Texture2D *staging;
    ID3D11Device_CreateTexture2D(dev, &td, NULL, &staging);

    LARGE_INTEGER f, t0, t1;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&t0);
    unsigned px = 0;
    for (int i = 0; i < frames; i++) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, clear);
        ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
        ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
        ID3D11DeviceContext_Draw(ctx, 3, 0);
        if (i == frames - 1) {
            ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)bb);
            D3D11_MAPPED_SUBRESOURCE m;
            if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &m))) {
                px = *(unsigned *)((char *)m.pData + (H / 2) * m.RowPitch + (W / 2) * 4);
                ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
            }
        }
        IDXGISwapChain_Present(sc, 0, 0);
    }
    QueryPerformanceCounter(&t1);
    double s = (double)(t1.QuadPart - t0.QuadPart) / f.QuadPart;
    unsigned r = px & 0xff, g = (px >> 8) & 0xff, b = (px >> 16) & 0xff;
    out("d3d11tri %d frames in %.2f s = %.1f fps, centre pixel rgb(%u,%u,%u)\n", frames, s, frames / s, r, g, b);
    int ok = r > 240 && g > 110 && g < 145 && b < 16;
    out("d3d11tri %s\n", ok ? "PASS" : "FAIL wrong pixel");
    return ok ? 0 : 1;
}
