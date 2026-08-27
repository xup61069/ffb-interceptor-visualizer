// SPDX-License-Identifier: GPL-3.0-only
#undef NDEBUG
#include "wrapper_dinput8.h"

#include <cassert>

namespace {

class FakeDirectInput final : public IDirectInput8A, public IDirectInput8W {
public:
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

    HRESULT STDMETHODCALLTYPE CreateDevice(REFGUID, IDirectInputDevice8A**, LPUNKNOWN) override {
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE CreateDevice(REFGUID, IDirectInputDevice8W**, LPUNKNOWN) override {
        return E_NOTIMPL;
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

}  // namespace

int main() {
    auto* fake = new FakeDirectInput();
    auto* wrapped_a = new WrapperDirectInput8A(static_cast<IDirectInput8A*>(fake));
    assert(wrapped_a && wrapped_a->valid());

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
    return 0;
}
