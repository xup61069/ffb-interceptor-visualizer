// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <windows.h>
#include <dinput.h>

namespace ffb {

using DirectInput8CreateFunction =
    HRESULT(WINAPI*)(HINSTANCE, DWORD, REFIID, LPVOID*, LPUNKNOWN);

HRESULT intercept_direct_input8_create(DirectInput8CreateFunction original,
                                       HINSTANCE instance,
                                       DWORD version,
                                       REFIID riid,
                                       LPVOID* out,
                                       LPUNKNOWN outer);

}  // namespace ffb
