// SPDX-License-Identifier: GPL-3.0-only
#include <windows.h>
#include <dinput.h>

#include <algorithm>
#include <cwchar>

#pragma comment(lib, "dinput8.lib")

namespace {

DWORD hold_time(int argc, wchar_t** argv) noexcept {
    for (int index = 1; index + 1 < argc; ++index) {
        if (std::wcscmp(argv[index], L"--hold-ms") != 0) continue;
        wchar_t* end = nullptr;
        const unsigned long parsed = std::wcstoul(argv[index + 1], &end, 10);
        if (end && *end == L'\0') {
            return static_cast<DWORD>(std::min<unsigned long>(parsed, 15000));
        }
    }
    return 3000;
}

HRESULT create_test_device(IDirectInput8W* direct_input) noexcept {
    IDirectInputDevice8W* device = nullptr;
    HRESULT result = direct_input->CreateDevice(GUID_SysKeyboard, &device, nullptr);
    if (FAILED(result)) {
        result = direct_input->CreateDevice(GUID_SysMouse, &device, nullptr);
    }
    if (device) device->Release();
    return result;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    IDirectInput8W* direct_input = nullptr;
    const HRESULT created = DirectInput8Create(
        GetModuleHandleW(nullptr), DIRECTINPUT_VERSION, IID_IDirectInput8W,
        reinterpret_cast<void**>(&direct_input), nullptr);
    HRESULT device_result = E_FAIL;
    if (SUCCEEDED(created) && direct_input) {
        device_result = create_test_device(direct_input);
        direct_input->Release();
    }
    Sleep(hold_time(argc, argv));
    return SUCCEEDED(created) && SUCCEEDED(device_result) ? 0 : 3;
}
