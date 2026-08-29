// SPDX-License-Identifier: GPL-3.0-only
#undef NDEBUG
#include "intercept_create.h"
#include "wrapper_dinput8.h"

#include <cassert>
#include <cstdint>

namespace {

class FakeDirectInput final : public IDirectInput8A, public IDirectInput8W {
public:
    LPUNKNOWN last_outer = nullptr;
    IDirectInputDevice8A* aggregated_device_a =
        reinterpret_cast<IDirectInputDevice8A*>(static_cast<std::uintptr_t>(0x1234));
    IDirectInputDevice8W* aggregated_device_w =
        reinterpret_cast<IDirectInputDevice8W*>(static_cast<std::uintptr_t>(0x5678));

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (riid == IID_IUnknown || riid == IID_IDirectInput8A) {
            *out = static_cast<IDirectInput8A*>(this);
        } else if (riid == IID_IDirectInput8W) {
            *out = static_cast<IDirectInput8W*>(this);
        } else {
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++m_refs; }
    ULONG STDMETHODCALLTYPE Release() override {
        assert(m_refs > 0);
        return --m_refs;
    }
    ULONG refs() const { return m_refs; }

    HRESULT STDMETHODCALLTYPE CreateDevice(REFGUID, IDirectInputDevice8A** out,
                                           LPUNKNOWN outer) override {
        last_outer = outer;
        *out = aggregated_device_a;
        return S_FALSE;
    }
    HRESULT STDMETHODCALLTYPE CreateDevice(REFGUID, IDirectInputDevice8W** out,
                                           LPUNKNOWN outer) override {
        last_outer = outer;
        *out = aggregated_device_w;
        return S_FALSE;
    }
    HRESULT STDMETHODCALLTYPE EnumDevices(DWORD, LPDIENUMDEVICESCALLBACKA, LPVOID, DWORD) override {
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE EnumDevices(DWORD, LPDIENUMDEVICESCALLBACKW, LPVOID, DWORD) override {
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE GetDeviceStatus(REFGUID) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE RunControlPanel(HWND, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Initialize(HINSTANCE, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE FindDevice(REFGUID, LPCSTR, LPGUID) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE FindDevice(REFGUID, LPCWSTR, LPGUID) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE EnumDevicesBySemantics(
        LPCSTR, LPDIACTIONFORMATA, LPDIENUMDEVICESBYSEMANTICSCBA, LPVOID, DWORD) override {
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE EnumDevicesBySemantics(
        LPCWSTR, LPDIACTIONFORMATW, LPDIENUMDEVICESBYSEMANTICSCBW, LPVOID, DWORD) override {
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE ConfigureDevices(
        LPDICONFIGUREDEVICESCALLBACK, LPDICONFIGUREDEVICESPARAMSA, DWORD, LPVOID) override {
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE ConfigureDevices(
        LPDICONFIGUREDEVICESCALLBACK, LPDICONFIGUREDEVICESPARAMSW, DWORD, LPVOID) override {
        return E_NOTIMPL;
    }

private:
    ULONG m_refs = 1;
};

FakeDirectInput* g_create_result = nullptr;

HRESULT WINAPI fake_direct_input_create(HINSTANCE, DWORD, REFIID riid,
                                        LPVOID* out, LPUNKNOWN) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (!g_create_result) return E_FAIL;
    if (riid == IID_IDirectInput8A) {
        *out = static_cast<IDirectInput8A*>(g_create_result);
    } else if (riid == IID_IDirectInput8W) {
        *out = static_cast<IDirectInput8W*>(g_create_result);
    } else {
        return E_NOINTERFACE;
    }
    return S_OK;
}

}  // namespace

int main() {
    auto* fake = new FakeDirectInput();
    auto* wrapped_a = new WrapperDirectInput8A(static_cast<IDirectInput8A*>(fake));
    assert(wrapped_a && wrapped_a->valid());

    // Aggregated objects are deliberately returned untouched: wrapping them
    // would violate the COM aggregation contract and could change identity.
    LPUNKNOWN outer = static_cast<IUnknown*>(static_cast<IDirectInput8A*>(fake));
    IDirectInputDevice8A* aggregated = nullptr;
    assert(wrapped_a->CreateDevice(GUID_ConstantForce, &aggregated, outer) == S_FALSE);
    assert(aggregated == fake->aggregated_device_a);
    assert(fake->last_outer == outer);

    void* out = nullptr;
    assert(wrapped_a->QueryInterface(IID_IDirectInput8W, &out) == S_OK);
    auto* wrapped_w = static_cast<IDirectInput8W*>(out);
    assert(wrapped_w != nullptr);

    void* unknown = nullptr;
    assert(wrapped_w->QueryInterface(IID_IUnknown, &unknown) == S_OK);
    assert(unknown == static_cast<void*>(static_cast<IDirectInput8A*>(wrapped_a)));

    // QI(W) and QI(IUnknown) share the same control-block reference count.
    assert(wrapped_w->Release() == 2);
    assert(static_cast<IDirectInput8A*>(unknown)->Release() == 1);
    assert(wrapped_a->Release() == 0);
    assert(fake->refs() == 0);

    // A wrapper that was never published must not consume the caller's real
    // interface reference while its shared A/W state is being torn down.
    auto* fallback_fake = new FakeDirectInput();
    auto* fallback_wrapper = new WrapperDirectInput8A(
        static_cast<IDirectInput8A*>(fallback_fake));
    assert(fallback_wrapper && fallback_wrapper->valid());
    fallback_wrapper->discard_unpublished();
    assert(fallback_fake->refs() == 1);
    assert(fallback_fake->Release() == 0);
    delete fallback_fake;

    // Proxy and launcher modes share the same creation wrapper.  The helper
    // preserves HRESULT while replacing only supported, non-aggregated A/W
    // interfaces with the telemetry-aware COM wrapper.
    g_create_result = new FakeDirectInput();
    void* created = nullptr;
    assert(ffb::intercept_direct_input8_create(
               fake_direct_input_create, nullptr, DIRECTINPUT_VERSION,
               IID_IDirectInput8A, &created, nullptr) == S_OK);
    assert(created != static_cast<void*>(
                          static_cast<IDirectInput8A*>(g_create_result)));
    assert(static_cast<IDirectInput8A*>(created)->Release() == 0);
    assert(g_create_result->refs() == 0);
    delete g_create_result;
    g_create_result = nullptr;

    delete fake;
    return 0;
}
