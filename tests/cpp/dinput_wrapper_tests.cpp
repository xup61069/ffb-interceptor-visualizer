// SPDX-License-Identifier: GPL-3.0-only
#undef NDEBUG
#include "intercept_create.h"
#include "wrapper_dinput8.h"
#include "wrapper_device8.h"
#include "wrapper_effect.h"

#include <cassert>
#include <cstdint>
#include <thread>

namespace {

class FakeEffect final : public IDirectInputEffect {
public:
    ULONG refs = 1;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (riid != IID_IUnknown && riid != IID_IDirectInputEffect) {
            return E_NOINTERFACE;
        }
        *out = static_cast<IDirectInputEffect*>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override {
        assert(refs > 0);
        return --refs;
    }
    HRESULT STDMETHODCALLTYPE Initialize(HINSTANCE, DWORD, REFGUID) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetEffectGuid(LPGUID guid) override {
        if (!guid) return E_POINTER;
        *guid = GUID_ConstantForce;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetParameters(LPDIEFFECT, DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE SetParameters(LPCDIEFFECT, DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Start(DWORD, DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Stop() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetEffectStatus(LPDWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Download() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Unload() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Escape(LPDIEFFESCAPE) override { return S_OK; }
};

class FakeDevice final : public IDirectInputDevice8A,
                         public IDirectInputDevice8W {
public:
    FakeEffect* created_effect = nullptr;
    BOOL last_effect_callback_result = DIENUM_CONTINUE;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (riid == IID_IUnknown || riid == IID_IDirectInputDevice8A) {
            *out = static_cast<IDirectInputDevice8A*>(this);
        } else if (riid == IID_IDirectInputDevice8W) {
            *out = static_cast<IDirectInputDevice8W*>(this);
        } else {
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override {
        return static_cast<ULONG>(InterlockedIncrement(&m_refs));
    }
    ULONG STDMETHODCALLTYPE Release() override {
        const LONG count = InterlockedDecrement(&m_refs);
        assert(count >= 0);
        return static_cast<ULONG>(count);
    }
    ULONG refs() {
        return static_cast<ULONG>(InterlockedCompareExchange(&m_refs, 0, 0));
    }

    HRESULT STDMETHODCALLTYPE GetCapabilities(LPDIDEVCAPS) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE EnumObjects(LPDIENUMDEVICEOBJECTSCALLBACKA, LPVOID, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE EnumObjects(LPDIENUMDEVICEOBJECTSCALLBACKW, LPVOID, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetProperty(REFGUID, LPDIPROPHEADER) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetProperty(REFGUID, LPCDIPROPHEADER) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Acquire() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Unacquire() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetDeviceState(DWORD, LPVOID) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetDeviceData(DWORD, LPDIDEVICEOBJECTDATA, LPDWORD, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetDataFormat(LPCDIDATAFORMAT) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetEventNotification(HANDLE) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetCooperativeLevel(HWND, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetObjectInfo(LPDIDEVICEOBJECTINSTANCEA, DWORD, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetObjectInfo(LPDIDEVICEOBJECTINSTANCEW, DWORD, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetDeviceInfo(LPDIDEVICEINSTANCEA info) override {
        if (!info) return E_POINTER;
        info->guidInstance = GUID_Joystick;
        info->tszProductName[0] = 'F';
        info->tszProductName[1] = '\0';
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetDeviceInfo(LPDIDEVICEINSTANCEW info) override {
        if (!info) return E_POINTER;
        info->guidInstance = GUID_Joystick;
        info->tszProductName[0] = L'F';
        info->tszProductName[1] = L'\0';
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE RunControlPanel(HWND, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Initialize(HINSTANCE, DWORD, REFGUID) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE CreateEffect(REFGUID, LPCDIEFFECT,
                                           LPDIRECTINPUTEFFECT* out,
                                           LPUNKNOWN) override {
        if (!out) return E_POINTER;
        *out = created_effect;
        return created_effect ? S_OK : E_FAIL;
    }
    HRESULT STDMETHODCALLTYPE EnumEffects(LPDIENUMEFFECTSCALLBACKA, LPVOID, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE EnumEffects(LPDIENUMEFFECTSCALLBACKW, LPVOID, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetEffectInfo(LPDIEFFECTINFOA, REFGUID) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetEffectInfo(LPDIEFFECTINFOW, REFGUID) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetForceFeedbackState(LPDWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SendForceFeedbackCommand(DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE EnumCreatedEffectObjects(
        LPDIENUMCREATEDEFFECTOBJECTSCALLBACK callback, LPVOID ref,
        DWORD) override {
        if (!callback) return E_INVALIDARG;
        if (!created_effect) return S_FALSE;
        last_effect_callback_result = callback(created_effect, ref);
        return S_FALSE;
    }
    HRESULT STDMETHODCALLTYPE Escape(LPDIEFFESCAPE) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Poll() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE SendDeviceData(DWORD, LPCDIDEVICEOBJECTDATA,
                                             LPDWORD, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE EnumEffectsInFile(
        LPCSTR, LPDIENUMEFFECTSINFILECALLBACK, LPVOID, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE EnumEffectsInFile(
        LPCWSTR, LPDIENUMEFFECTSINFILECALLBACK, LPVOID, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE WriteEffectToFile(LPCSTR, DWORD, LPDIFILEEFFECT,
                                                DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE WriteEffectToFile(LPCWSTR, DWORD, LPDIFILEEFFECT,
                                                DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE BuildActionMap(LPDIACTIONFORMATA, LPCSTR, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE BuildActionMap(LPDIACTIONFORMATW, LPCWSTR, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetActionMap(LPDIACTIONFORMATA, LPCSTR, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetActionMap(LPDIACTIONFORMATW, LPCWSTR, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetImageInfo(LPDIDEVICEIMAGEINFOHEADERA) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetImageInfo(LPDIDEVICEIMAGEINFOHEADERW) override { return E_NOTIMPL; }

private:
    volatile LONG m_refs = 1;
};

class FakeDirectInput final : public IDirectInput8A, public IDirectInput8W {
public:
    LPUNKNOWN last_outer = nullptr;
    IDirectInputDevice8A* aggregated_device_a =
        reinterpret_cast<IDirectInputDevice8A*>(static_cast<std::uintptr_t>(0x1234));
    IDirectInputDevice8W* aggregated_device_w =
        reinterpret_cast<IDirectInputDevice8W*>(static_cast<std::uintptr_t>(0x5678));
    FakeDevice* semantics_device = nullptr;
    BOOL last_semantics_result_a = DIENUM_CONTINUE;
    BOOL last_semantics_result_w = DIENUM_CONTINUE;

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
        LPCSTR, LPDIACTIONFORMATA, LPDIENUMDEVICESBYSEMANTICSCBA callback,
        LPVOID ref, DWORD) override {
        if (!callback) return E_INVALIDARG;
        DIDEVICEINSTANCEA instance{};
        instance.dwSize = sizeof(instance);
        instance.guidInstance = GUID_Joystick;
        instance.tszProductName[0] = 'F';
        instance.tszProductName[1] = '\0';
        last_semantics_result_a = callback(
            &instance, static_cast<IDirectInputDevice8A*>(semantics_device),
            DIEDBS_MAPPEDPRI1, 3, ref);
        return S_FALSE;
    }
    HRESULT STDMETHODCALLTYPE EnumDevicesBySemantics(
        LPCWSTR, LPDIACTIONFORMATW, LPDIENUMDEVICESBYSEMANTICSCBW callback,
        LPVOID ref, DWORD) override {
        if (!callback) return E_INVALIDARG;
        DIDEVICEINSTANCEW instance{};
        instance.dwSize = sizeof(instance);
        instance.guidInstance = GUID_Joystick;
        instance.tszProductName[0] = L'F';
        instance.tszProductName[1] = L'\0';
        last_semantics_result_w = callback(
            &instance, static_cast<IDirectInputDevice8W*>(semantics_device),
            DIEDBS_MAPPEDPRI2, 2, ref);
        return S_FALSE;
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

struct SemanticsAState {
    FakeDevice* raw = nullptr;
    IDirectInputDevice8A* retained = nullptr;
    int marker = 0;
};

BOOL CALLBACK capture_semantics_a(LPCDIDEVICEINSTANCEA instance,
                                  IDirectInputDevice8A* device, DWORD flags,
                                  DWORD remaining, LPVOID ref) {
    auto* state = static_cast<SemanticsAState*>(ref);
    assert(state && state->marker == 41);
    assert(instance && IsEqualGUID(instance->guidInstance, GUID_Joystick));
    assert(device != static_cast<IDirectInputDevice8A*>(state->raw));
    assert(flags == DIEDBS_MAPPEDPRI1);
    assert(remaining == 3);

    void* queried = nullptr;
    assert(device->QueryInterface(IID_IDirectInputDevice8A, &queried) == S_OK);
    assert(queried == device);
    static_cast<IDirectInputDevice8A*>(queried)->Release();
    device->AddRef();
    state->retained = device;
    return DIENUM_STOP;
}

struct SemanticsWState {
    FakeDevice* raw = nullptr;
    IUnknown* expected_unknown = nullptr;
    IDirectInputDevice8W* retained = nullptr;
    int marker = 0;
};

BOOL CALLBACK inspect_semantics_w(LPCDIDEVICEINSTANCEW instance,
                                  IDirectInputDevice8W* device, DWORD flags,
                                  DWORD remaining, LPVOID ref) {
    auto* state = static_cast<SemanticsWState*>(ref);
    assert(state && state->marker == 42);
    assert(instance && IsEqualGUID(instance->guidInstance, GUID_Joystick));
    assert(device != static_cast<IDirectInputDevice8W*>(state->raw));
    assert(flags == DIEDBS_MAPPEDPRI2);
    assert(remaining == 2);

    void* unknown = nullptr;
    assert(device->QueryInterface(IID_IUnknown, &unknown) == S_OK);
    assert(unknown == state->expected_unknown);
    void* queried_w = nullptr;
    assert(static_cast<IUnknown*>(unknown)->QueryInterface(
               IID_IDirectInputDevice8W, &queried_w) == S_OK);
    assert(queried_w == device);
    static_cast<IDirectInputDevice8W*>(queried_w)->Release();
    device->AddRef();
    state->retained = device;
    static_cast<IUnknown*>(unknown)->Release();
    return DIENUM_CONTINUE;
}

struct EffectState {
    IDirectInputEffect* expected = nullptr;
    FakeEffect* raw = nullptr;
    int marker = 0;
};

BOOL CALLBACK inspect_created_effect(IDirectInputEffect* effect, LPVOID ref) {
    auto* state = static_cast<EffectState*>(ref);
    assert(state && state->marker == 73);
    assert(effect == state->expected);
    assert(effect != static_cast<IDirectInputEffect*>(state->raw));
    void* unknown = nullptr;
    assert(effect->QueryInterface(IID_IUnknown, &unknown) == S_OK);
    assert(unknown == effect);
    static_cast<IUnknown*>(unknown)->Release();
    return DIENUM_STOP;
}

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
    auto* semantics_device = new FakeDevice();
    fake->semantics_device = semantics_device;
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

    // EnumDevicesBySemantics lends real device interfaces to its callback.
    // Both A and W callbacks must instead see a telemetry-aware wrapper, with
    // callback arguments and return values passed through unchanged.
    SemanticsAState semantics_a{semantics_device, nullptr, 41};
    assert(wrapped_a->EnumDevicesBySemantics(
               nullptr, nullptr, &capture_semantics_a, &semantics_a, 0) ==
           S_FALSE);
    assert(fake->last_semantics_result_a == DIENUM_STOP);
    assert(semantics_a.retained != nullptr);
    void* semantics_unknown_raw = nullptr;
    assert(semantics_a.retained->QueryInterface(
               IID_IUnknown, &semantics_unknown_raw) == S_OK);
    auto* semantics_unknown = static_cast<IUnknown*>(semantics_unknown_raw);

    SemanticsWState semantics_w{semantics_device, semantics_unknown, nullptr,
                                42};
    assert(wrapped_w->EnumDevicesBySemantics(
               nullptr, nullptr, &inspect_semantics_w, &semantics_w, 0) ==
           S_FALSE);
    assert(fake->last_semantics_result_w == DIENUM_CONTINUE);
    assert(semantics_w.retained != nullptr);
    // Both callbacks borrowed the same real COM object while the A wrapper
    // remained live. They must therefore share one canonical IUnknown and one
    // wrapper control block instead of splitting SimHub telemetry by callback.
    assert(semantics_w.retained->Release() == 2);
    assert(semantics_unknown->Release() == 1);
    assert(semantics_a.retained->Release() == 0);
    assert(semantics_device->refs() == 1);

    // Concurrent publications of the same real COM identity must converge on
    // one wrapper while both returned references remain independently owned.
    auto* concurrent_device = new FakeDevice();
    concurrent_device->AddRef();
    concurrent_device->AddRef();
    WrapperDevice8A* concurrent_first = nullptr;
    WrapperDevice8A* concurrent_second = nullptr;
    bool concurrent_first_created = false;
    bool concurrent_second_created = false;
    std::thread first_publisher([&] {
        concurrent_first = WrapperDevice8A::publish_or_add_ref(
            static_cast<IDirectInputDevice8A*>(concurrent_device), 81,
            &concurrent_first_created);
    });
    std::thread second_publisher([&] {
        concurrent_second = WrapperDevice8A::publish_or_add_ref(
            static_cast<IDirectInputDevice8A*>(concurrent_device), 82,
            &concurrent_second_created);
    });
    first_publisher.join();
    second_publisher.join();
    assert(concurrent_first != nullptr);
    assert(concurrent_first == concurrent_second);
    assert(concurrent_first_created != concurrent_second_created);
    assert(concurrent_first->Release() == 1);
    assert(concurrent_second->Release() == 0);
    assert(concurrent_device->refs() == 1);
    assert(concurrent_device->Release() == 0);
    delete concurrent_device;

    // A null callback is still forwarded as null so the runtime performs its
    // normal argument validation rather than calling our thunk.
    assert(wrapped_a->EnumDevicesBySemantics(
               nullptr, nullptr, nullptr, nullptr, 0) == E_INVALIDARG);

    void* unknown = nullptr;
    assert(wrapped_w->QueryInterface(IID_IUnknown, &unknown) == S_OK);
    assert(unknown == static_cast<void*>(static_cast<IDirectInput8A*>(wrapped_a)));

    // QI(W) and QI(IUnknown) share the same control-block reference count.
    assert(wrapped_w->Release() == 2);
    assert(static_cast<IDirectInput8A*>(unknown)->Release() == 1);
    assert(wrapped_a->Release() == 0);
    assert(fake->refs() == 0);

    // Effects returned by EnumCreatedEffectObjects must preserve the exact
    // wrapper identity originally published by CreateEffect.
    auto* effect_device = new FakeDevice();
    auto* real_effect = new FakeEffect();
    effect_device->created_effect = real_effect;
    auto* wrapped_device = new WrapperDevice8A(
        static_cast<IDirectInputDevice8A*>(effect_device), 61);
    assert(wrapped_device && wrapped_device->valid());

    IDirectInputEffect* published_effect = nullptr;
    assert(wrapped_device->CreateEffect(GUID_ConstantForce, nullptr,
                                        &published_effect, nullptr) == S_OK);
    assert(published_effect != nullptr);
    assert(published_effect != static_cast<IDirectInputEffect*>(real_effect));
    EffectState effect_state{published_effect, real_effect, 73};
    assert(wrapped_device->EnumCreatedEffectObjects(
               &inspect_created_effect, &effect_state, 0) == S_FALSE);
    assert(effect_device->last_effect_callback_result == DIENUM_STOP);
    assert(wrapped_device->EnumCreatedEffectObjects(nullptr, nullptr, 0) ==
           E_INVALIDARG);
    assert(published_effect->Release() == 0);
    assert(real_effect->refs == 0);
    assert(WrapperEffect::find_and_add_ref(real_effect) == nullptr);
    assert(wrapped_device->Release() == 0);
    assert(effect_device->refs() == 0);
    delete real_effect;
    delete effect_device;

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

    assert(semantics_device->Release() == 0);
    delete semantics_device;
    delete fake;
    return 0;
}
