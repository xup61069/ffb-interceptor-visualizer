// SPDX-License-Identifier: GPL-3.0-only
#include "wrapper_effect.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>

namespace {

class FakeEffect final : public IDirectInputEffect {
public:
    HRESULT start_result = E_ACCESSDENIED;
    HRESULT set_result = E_INVALIDARG;
    DWORD last_iterations = 0;
    DWORD last_flags = 0;
    LPCDIEFFECT last_parameters = nullptr;
    ULONG refs = 1;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (riid == IID_IUnknown || riid == IID_IDirectInputEffect) {
            *out = this;
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { return refs ? --refs : 0; }
    HRESULT STDMETHODCALLTYPE Initialize(HINSTANCE, DWORD, REFGUID) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetEffectGuid(LPGUID guid) override {
        if (!guid) return E_POINTER;
        *guid = GUID_ConstantForce;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetParameters(LPDIEFFECT, DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE SetParameters(LPCDIEFFECT parameters, DWORD flags) override {
        last_parameters = parameters;
        last_flags = flags;
        return set_result;
    }
    HRESULT STDMETHODCALLTYPE Start(DWORD iterations, DWORD flags) override {
        last_iterations = iterations;
        last_flags = flags;
        return start_result;
    }
    HRESULT STDMETHODCALLTYPE Stop() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetEffectStatus(LPDWORD status) override {
        if (status) *status = 0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Download() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Unload() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Escape(LPDIEFFESCAPE) override { return S_OK; }
};

}  // namespace

int main() {
    auto* fake = new FakeEffect();
    auto* wrapper = new WrapperEffect(fake, 11, 22, GUID_ConstantForce);

    void* unknown = nullptr;
    assert(wrapper->QueryInterface(IID_IUnknown, &unknown) == S_OK);
    assert(unknown == static_cast<IDirectInputEffect*>(wrapper));
    assert(static_cast<IUnknown*>(unknown)->Release() == 1);

    DIEFFECT parameters{};
    DICONSTANTFORCE constant{1234};
    parameters.dwSize = sizeof(parameters);
    parameters.cbTypeSpecificParams = sizeof(constant);
    parameters.lpvTypeSpecificParams = &constant;
    assert(wrapper->SetParameters(&parameters, DIEP_TYPESPECIFICPARAMS) == E_INVALIDARG);
    assert(fake->last_parameters == &parameters);
    assert(fake->last_flags == DIEP_TYPESPECIFICPARAMS);

    assert(wrapper->Start(7, DIES_NODOWNLOAD) == E_ACCESSDENIED);
    assert(fake->last_iterations == 7);
    assert(fake->last_flags == DIES_NODOWNLOAD);

    assert(wrapper->Release() == 0);
    assert(fake->refs == 0);
    delete fake;
    return 0;
}
