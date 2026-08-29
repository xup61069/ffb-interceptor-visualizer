// SPDX-License-Identifier: GPL-3.0-only
#include "intercept_create.h"

#include "telemetry.h"
#include "wrapper_dinput8.h"

#include <new>

namespace ffb {

HRESULT intercept_direct_input8_create(DirectInput8CreateFunction original,
                                       HINSTANCE instance,
                                       DWORD version,
                                       REFIID riid,
                                       LPVOID* out,
                                       LPUNKNOWN outer) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (!original) return DIERR_NOTINITIALIZED;

    const HRESULT hr = original(instance, version, riid, out, outer);
    if (FAILED(hr) || !*out || outer != nullptr) return hr;

    Telemetry::instance().start();
    if (riid == IID_IDirectInput8W) {
        auto* wrapped = new (std::nothrow) WrapperDirectInput8W(
            static_cast<IDirectInput8W*>(*out));
        if (wrapped && wrapped->valid()) {
            *out = static_cast<IDirectInput8W*>(wrapped);
        } else if (wrapped) {
            wrapped->discard_unpublished();
        }
    } else if (riid == IID_IDirectInput8A) {
        auto* wrapped = new (std::nothrow) WrapperDirectInput8A(
            static_cast<IDirectInput8A*>(*out));
        if (wrapped && wrapped->valid()) {
            *out = static_cast<IDirectInput8A*>(wrapped);
        } else if (wrapped) {
            wrapped->discard_unpublished();
        }
    }
    return hr;
}

}  // namespace ffb
