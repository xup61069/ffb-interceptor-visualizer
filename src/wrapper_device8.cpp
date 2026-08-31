// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Valmantas Paliksa
#include "wrapper_device8.h"
#include "wrapper_effect.h"
#include "telemetry.h"

#include <new>

namespace {

struct EffectCallbackContext {
    LPDIENUMCREATEDEFFECTOBJECTSCALLBACK callback = nullptr;
    LPVOID ref = nullptr;
};

void emit_effect(std::uint32_t device_id, std::uint32_t effect_id, REFGUID guid,
                 LPCDIEFFECT parameters, HRESULT hr) noexcept {
    ffb::Event event{};
    event.type = ffb::MessageType::EffectCreated;
    event.effect_kind = ffb::effect_kind_from_guid(guid);
    event.process_id = GetCurrentProcessId();
    event.device_id = device_id;
    event.effect_id = effect_id;
    event.effect_guid = guid;
    event.hresult = hr;
    event.effect_parameter_presence = parameters
        ? ffb::EffectParameterPresence::Present
        : ffb::EffectParameterPresence::Absent;
    ffb::fill_effect_parameters(event, parameters);
    ffb::Telemetry::instance().emit(event);
}

void emit_property(std::uint32_t device_id, REFGUID property,
                   LPCDIPROPHEADER header, HRESULT hr) noexcept {
    if (!IsEqualGUID(property, DIPROP_FFGAIN) && !IsEqualGUID(property, DIPROP_AUTOCENTER)) return;
    ffb::Event event{};
    event.type = ffb::MessageType::DevicePropertyChanged;
    event.process_id = GetCurrentProcessId();
    event.device_id = device_id;
    event.property_id = IsEqualGUID(property, DIPROP_FFGAIN) ? 1u : 2u;
    event.hresult = hr;
    __try {
        if (header && header->dwSize >= sizeof(DIPROPDWORD)) {
            event.gain = reinterpret_cast<const DIPROPDWORD*>(header)->dwData;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        event.gain = 0;
    }
    ffb::Telemetry::instance().emit(event);
}

void emit_device_command(std::uint32_t device_id, DWORD command,
                         HRESULT hr) noexcept {
    ffb::Event event{};
    event.type = ffb::MessageType::DeviceCommand;
    event.process_id = GetCurrentProcessId();
    event.device_id = device_id;
    event.di_flags = command;
    event.hresult = hr;
    ffb::Telemetry::instance().emit(event);
}

BOOL CALLBACK created_effect_callback(IDirectInputEffect* real, LPVOID opaque) {
    auto* context = static_cast<EffectCallbackContext*>(opaque);
    if (!context || !context->callback) return DIENUM_STOP;

    WrapperEffect* wrapped = WrapperEffect::find_and_add_ref(real);
    if (!wrapped) {
        // Allocation/aggregation fail-open paths can legitimately have no
        // wrapper. Preserve DirectInput behaviour instead of hiding an effect.
        return context->callback(real, context->ref);
    }
    const BOOL result = context->callback(wrapped, context->ref);
    wrapped->Release();
    return result;
}

}  // namespace

struct WrapperDevice8State {
    static SRWLOCK registry_lock;
    static WrapperDevice8State* registry_head;

    volatile LONG ref_count = 1;
    // DirectInput devices begin unacquired. This gate suppresses repeated
    // STOPALL telemetry while a backgrounded game polls and receives the
    // same DIERR_INPUTLOST/DIERR_NOTACQUIRED result every frame.
    volatile LONG playback_invalidated = 1;
    IDirectInputDevice8A* real_a = nullptr;
    IDirectInputDevice8W* real_w = nullptr;
    WrapperDevice8A* wrapper_a = nullptr;
    WrapperDevice8W* wrapper_w = nullptr;
    IUnknown* identity = nullptr;
    WrapperDevice8State* registry_next = nullptr;
    bool registered = false;

    bool valid() const noexcept {
        // A successful QI for the alternate A/W interface creates an
        // additional real reference that must have a matching wrapper.
        return (!real_a || wrapper_a) && (!real_w || wrapper_w);
    }

    ~WrapperDevice8State() {
        delete wrapper_a;
        delete wrapper_w;
        if (real_a) real_a->Release();
        if (real_w) real_w->Release();
    }

    void* canonical_unknown() const noexcept {
        if (wrapper_a) return static_cast<IDirectInputDevice8A*>(wrapper_a);
        return static_cast<IDirectInputDevice8W*>(wrapper_w);
    }

    ULONG add_ref() noexcept {
        return static_cast<ULONG>(InterlockedIncrement(&ref_count));
    }

    void unregister_locked() noexcept {
        if (!registered) return;
        WrapperDevice8State** link = &registry_head;
        while (*link && *link != this) link = &((*link)->registry_next);
        if (*link == this) *link = registry_next;
        registry_next = nullptr;
        registered = false;
    }

    ULONG release() noexcept {
        AcquireSRWLockExclusive(&registry_lock);
        const ULONG count = static_cast<ULONG>(InterlockedDecrement(&ref_count));
        if (count == 0) unregister_locked();
        ReleaseSRWLockExclusive(&registry_lock);
        if (count == 0) delete this;
        return count;
    }
};

SRWLOCK WrapperDevice8State::registry_lock = SRWLOCK_INIT;
WrapperDevice8State* WrapperDevice8State::registry_head = nullptr;

namespace {

bool acquisition_is_lost(HRESULT hr) noexcept {
    return hr == DIERR_INPUTLOST || hr == DIERR_NOTACQUIRED ||
           hr == DIERR_OTHERAPPHASPRIO;
}

void invalidate_playback(WrapperDevice8State* state, std::uint32_t device_id,
                         HRESULT telemetry_hr = DI_OK) noexcept {
    if (state && InterlockedExchange(&state->playback_invalidated, 1) == 0) {
        emit_device_command(device_id, DISFFC_STOPALL, telemetry_hr);
    }
}

}  // namespace

template<bool U>
WrapperDevice8<U>::WrapperDevice8(Base* real, std::uint32_t device_id)
    : m_real(real), m_device_id(device_id) {
    m_state = new (std::nothrow) WrapperDevice8State();
    if (!m_state) return;

    if constexpr (U) {
        m_state->real_w = static_cast<IDirectInputDevice8W*>(real);
        m_state->wrapper_w = static_cast<WrapperDevice8W*>(this);
        real->QueryInterface(IID_IDirectInputDevice8A,
                             reinterpret_cast<void**>(&m_state->real_a));
        if (m_state->real_a) {
            m_state->wrapper_a = new (std::nothrow)
                WrapperDevice8A(m_state, m_state->real_a, device_id);
        }
    } else {
        m_state->real_a = static_cast<IDirectInputDevice8A*>(real);
        m_state->wrapper_a = static_cast<WrapperDevice8A*>(this);
        real->QueryInterface(IID_IDirectInputDevice8W,
                             reinterpret_cast<void**>(&m_state->real_w));
        if (m_state->real_w) {
            m_state->wrapper_w = new (std::nothrow)
                WrapperDevice8W(m_state, m_state->real_w, device_id);
        }
    }

    IUnknown* identity = nullptr;
    if (real && SUCCEEDED(real->QueryInterface(
                    IID_IUnknown, reinterpret_cast<void**>(&identity))) &&
        identity) {
        // The owned A/W interface references keep the COM object alive, so
        // the canonical IUnknown pointer is a stable lookup key without
        // retaining an extra reference.
        m_state->identity = identity;
        identity->Release();
    }
}

template<bool U>
WrapperDevice8<U>::WrapperDevice8(WrapperDevice8State* state, Base* real,
                                  std::uint32_t device_id)
    : m_real(real), m_device_id(device_id), m_state(state) {}

template<bool U>
WrapperDevice8<U>::~WrapperDevice8() = default;

template<bool U>
bool WrapperDevice8<U>::valid() const noexcept {
    return m_state != nullptr && m_state->valid();
}

template<bool U>
WrapperDevice8<U>* WrapperDevice8<U>::publish_or_add_ref(
    Base* real, std::uint32_t device_id, bool* created) noexcept {
    if (created) *created = false;
    if (!real) return nullptr;

    auto* candidate = new (std::nothrow) WrapperDevice8<U>(real, device_id);
    if (!candidate || !candidate->valid()) {
        if (candidate) candidate->discard_unpublished();
        return nullptr;
    }

    WrapperDevice8State* candidate_state = candidate->m_state;
    WrapperDevice8<U>* existing = nullptr;
    bool identity_without_alias = false;

    AcquireSRWLockExclusive(&WrapperDevice8State::registry_lock);
    for (WrapperDevice8State* current = WrapperDevice8State::registry_head;
         current; current = current->registry_next) {
        const bool exact_pointer =
            (current->real_a &&
             static_cast<void*>(current->real_a) == static_cast<void*>(real)) ||
            (current->real_w &&
             static_cast<void*>(current->real_w) == static_cast<void*>(real));
        const bool same_identity = candidate_state->identity &&
                                   current->identity == candidate_state->identity;
        if (!exact_pointer && !same_identity) continue;

        if constexpr (U) {
            existing = current->wrapper_w;
        } else {
            existing = current->wrapper_a;
        }
        if (existing) current->add_ref();
        else identity_without_alias = true;
        break;
    }

    if (!existing && !identity_without_alias) {
        candidate_state->registry_next = WrapperDevice8State::registry_head;
        WrapperDevice8State::registry_head = candidate_state;
        candidate_state->registered = true;
        if (created) *created = true;
    }
    ReleaseSRWLockExclusive(&WrapperDevice8State::registry_lock);

    if (existing) {
        // The existing shared state now owns the returned wrapper reference;
        // destroy the unpublished candidate and its transferred real ref.
        candidate->Release();
        return existing;
    }
    if (identity_without_alias) {
        // Never publish a second canonical IUnknown merely because a broken
        // runtime failed the original A/W alias query. Preserve fail-open raw
        // forwarding and leave ownership of `real` with the caller.
        candidate->discard_unpublished();
        return nullptr;
    }
    return candidate;
}

template<bool U>
void WrapperDevice8<U>::discard_unpublished() noexcept {
    if (!m_state) {
        delete this;
        return;
    }
    // Preserve the caller-owned original interface reference.  Any alias
    // reference acquired by QueryInterface remains state-owned and is
    // released when the shared control block is destroyed.
    if constexpr (U) {
        m_state->real_w = nullptr;
    } else {
        m_state->real_a = nullptr;
    }
    m_real = nullptr;
    Release();
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::QueryInterface(REFIID riid, void** out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (!m_state) return E_NOINTERFACE;
    if (riid == IID_IUnknown) {
        *out = m_state->canonical_unknown();
        m_state->add_ref();
        return S_OK;
    }
    if (riid == IID_IDirectInputDevice8A && m_state->wrapper_a) {
        *out = static_cast<IDirectInputDevice8A*>(m_state->wrapper_a);
        m_state->add_ref();
        return S_OK;
    }
    if (riid == IID_IDirectInputDevice8W && m_state->wrapper_w) {
        *out = static_cast<IDirectInputDevice8W*>(m_state->wrapper_w);
        m_state->add_ref();
        return S_OK;
    }
    return m_real ? m_real->QueryInterface(riid, out) : E_NOINTERFACE;
}

template<bool U>
ULONG STDMETHODCALLTYPE WrapperDevice8<U>::AddRef() {
    return m_state ? m_state->add_ref() : 0;
}

template<bool U>
ULONG STDMETHODCALLTYPE WrapperDevice8<U>::Release() {
    return m_state ? m_state->release() : 0;
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetCapabilities(LPDIDEVCAPS value) {
    return m_real->GetCapabilities(value);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::EnumObjects(EnumObjCbT callback, LPVOID ref, DWORD flags) {
    return m_real->EnumObjects(callback, ref, flags);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetProperty(REFGUID guid, LPDIPROPHEADER header) {
    return m_real->GetProperty(guid, header);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::SetProperty(REFGUID guid, LPCDIPROPHEADER header) {
    const HRESULT hr = m_real->SetProperty(guid, header);
    emit_property(m_device_id, guid, header, hr);
    return hr;
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::Acquire() {
    const HRESULT hr = m_real->Acquire();
    if (SUCCEEDED(hr) && m_state) {
        InterlockedExchange(&m_state->playback_invalidated, 0);
    } else if (acquisition_is_lost(hr)) {
        invalidate_playback(m_state, m_device_id);
    }
    return hr;
}
template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::Unacquire() {
    const HRESULT hr = m_real->Unacquire();
    if (SUCCEEDED(hr)) {
        // DirectInput unloads and therefore stops every effect on a
        // successfully unacquired device. Reuse STOPALL on the wire so
        // consumers retain cached parameters without reporting stale output.
        invalidate_playback(m_state, m_device_id, hr);
    }
    return hr;
}
template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetDeviceState(DWORD size,
                                                             LPVOID data) {
    const HRESULT hr = m_real->GetDeviceState(size, data);
    if (acquisition_is_lost(hr)) invalidate_playback(m_state, m_device_id);
    return hr;
}
template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetDeviceData(
    DWORD size, LPDIDEVICEOBJECTDATA data, LPDWORD count, DWORD flags) {
    const HRESULT hr = m_real->GetDeviceData(size, data, count, flags);
    if (acquisition_is_lost(hr)) invalidate_playback(m_state, m_device_id);
    return hr;
}
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::SetDataFormat(LPCDIDATAFORMAT format) { return m_real->SetDataFormat(format); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::SetEventNotification(HANDLE event) { return m_real->SetEventNotification(event); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::SetCooperativeLevel(HWND window, DWORD flags) { return m_real->SetCooperativeLevel(window, flags); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetObjectInfo(DevObjInstT* info, DWORD object, DWORD how) { return m_real->GetObjectInfo(info, object, how); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetDeviceInfo(DevInstT* info) { return m_real->GetDeviceInfo(info); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::RunControlPanel(HWND owner, DWORD flags) { return m_real->RunControlPanel(owner, flags); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::Initialize(HINSTANCE instance, DWORD version, REFGUID guid) { return m_real->Initialize(instance, version, guid); }

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::CreateEffect(REFGUID guid, LPCDIEFFECT parameters,
                                                            LPDIRECTINPUTEFFECT* out, LPUNKNOWN outer) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (!m_real) return DIERR_NOTINITIALIZED;
    IDirectInputEffect* real = nullptr;
    const HRESULT hr = m_real->CreateEffect(guid, parameters, &real, outer);
    if (FAILED(hr) || !real || outer != nullptr) {
        emit_effect(m_device_id, 0, guid, parameters, hr);
        *out = real;
        return hr;
    }
    const std::uint32_t effect_id = ffb::Telemetry::instance().next_effect_id();
    auto* wrapped = new (std::nothrow) WrapperEffect(real, m_device_id, effect_id, guid);
    if (!wrapped) {
        emit_effect(m_device_id, effect_id, guid, parameters, hr);
        *out = real;
        return hr;
    }
    emit_effect(m_device_id, effect_id, guid, parameters, hr);
    *out = wrapped;
    return hr;
}

template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::EnumEffects(EnumFxCbT callback, LPVOID ref, DWORD type) { return m_real->EnumEffects(callback, ref, type); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetEffectInfo(EffInfoT* info, REFGUID guid) { return m_real->GetEffectInfo(info, guid); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetForceFeedbackState(LPDWORD value) { return m_real->GetForceFeedbackState(value); }

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::SendForceFeedbackCommand(DWORD flags) {
    const HRESULT hr = m_real->SendForceFeedbackCommand(flags);
    emit_device_command(m_device_id, flags, hr);
    return hr;
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::EnumCreatedEffectObjects(
    LPDIENUMCREATEDEFFECTOBJECTSCALLBACK callback, LPVOID ref, DWORD flags) {
    if (!callback) return m_real->EnumCreatedEffectObjects(callback, ref, flags);
    EffectCallbackContext context{callback, ref};
    return m_real->EnumCreatedEffectObjects(&created_effect_callback, &context,
                                            flags);
}
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::Escape(LPDIEFFESCAPE escape) { return m_real->Escape(escape); }
template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::Poll() {
    const HRESULT hr = m_real->Poll();
    if (acquisition_is_lost(hr)) invalidate_playback(m_state, m_device_id);
    return hr;
}
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::SendDeviceData(DWORD size, LPCDIDEVICEOBJECTDATA data, LPDWORD count, DWORD flags) { return m_real->SendDeviceData(size, data, count, flags); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::BuildActionMap(ActFmtT* format, const Char* user, DWORD flags) { return m_real->BuildActionMap(format, user, flags); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::SetActionMap(ActFmtT* format, const Char* user, DWORD flags) { return m_real->SetActionMap(format, user, flags); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetImageInfo(std::conditional_t<U, LPDIDEVICEIMAGEINFOHEADERW, LPDIDEVICEIMAGEINFOHEADERA> info) { return m_real->GetImageInfo(info); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::EnumEffectsInFile(const Char* file, LPDIENUMEFFECTSINFILECALLBACK callback, LPVOID ref, DWORD flags) { return m_real->EnumEffectsInFile(file, callback, ref, flags); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::WriteEffectToFile(const Char* file, DWORD entries, LPDIFILEEFFECT effects, DWORD flags) { return m_real->WriteEffectToFile(file, entries, effects, flags); }

template class WrapperDevice8<false>;
template class WrapperDevice8<true>;
