// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Valmantas Paliksa
#include "wrapper_effect.h"
#include "telemetry.h"

WrapperEffect::WrapperEffect(IDirectInputEffect* real, std::uint32_t device_id,
                             std::uint32_t effect_id, REFGUID effect_guid)
    : m_real(real), m_guid(effect_guid), m_device_id(device_id), m_effect_id(effect_id) {}

WrapperEffect::~WrapperEffect() {
    if (m_real) m_real->Release();
}

HRESULT STDMETHODCALLTYPE WrapperEffect::QueryInterface(REFIID riid, void** out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (riid == IID_IUnknown || riid == IID_IDirectInputEffect) {
        *out = static_cast<IDirectInputEffect*>(this);
        AddRef();
        return S_OK;
    }
    return m_real ? m_real->QueryInterface(riid, out) : E_NOINTERFACE;
}

ULONG STDMETHODCALLTYPE WrapperEffect::AddRef() {
    return static_cast<ULONG>(InterlockedIncrement(&m_ref_count));
}

ULONG STDMETHODCALLTYPE WrapperEffect::Release() {
    const ULONG count = static_cast<ULONG>(InterlockedDecrement(&m_ref_count));
    if (count == 0) {
        ffb::Event event{};
        event.type = ffb::MessageType::EffectCommand;
        event.effect_kind = ffb::effect_kind_from_guid(m_guid);
        event.command = static_cast<std::uint16_t>(ffb::EffectCommand::Release);
        event.process_id = GetCurrentProcessId();
        event.device_id = m_device_id;
        event.effect_id = m_effect_id;
        event.effect_guid = m_guid;
        event.qpc_ticks = ffb::qpc_now();
        ffb::Telemetry::instance().emit(event);
        delete this;
    }
    return count;
}

HRESULT STDMETHODCALLTYPE WrapperEffect::Initialize(HINSTANCE instance, DWORD version,
                                                     REFGUID guid) {
    return m_real ? m_real->Initialize(instance, version, guid) : DI_OK;
}

HRESULT STDMETHODCALLTYPE WrapperEffect::GetEffectGuid(LPGUID guid) {
    // Preserve the real COM method's output and HRESULT.  The cached GUID is
    // telemetry metadata only; substituting it here would change DirectInput
    // behaviour for devices that reject or normalize this query.
    return m_real ? m_real->GetEffectGuid(guid) : DIERR_UNSUPPORTED;
}

HRESULT STDMETHODCALLTYPE WrapperEffect::GetParameters(LPDIEFFECT effect, DWORD flags) {
    return m_real ? m_real->GetParameters(effect, flags) : DIERR_UNSUPPORTED;
}

HRESULT STDMETHODCALLTYPE WrapperEffect::SetParameters(LPCDIEFFECT effect, DWORD flags) {
    const HRESULT hr = m_real ? m_real->SetParameters(effect, flags) : DIERR_UNSUPPORTED;
    ffb::Event event{};
    event.type = ffb::MessageType::EffectParametersChanged;
    event.effect_kind = ffb::effect_kind_from_guid(m_guid);
    event.process_id = GetCurrentProcessId();
    event.device_id = m_device_id;
    event.effect_id = m_effect_id;
    event.effect_guid = m_guid;
    event.hresult = hr;
    event.flags = flags;
    ffb::fill_effect_parameters(event, effect);
    ffb::Telemetry::instance().emit(event);
    return hr;
}

HRESULT STDMETHODCALLTYPE WrapperEffect::Start(DWORD iterations, DWORD flags) {
    const HRESULT hr = m_real ? m_real->Start(iterations, flags) : DIERR_UNSUPPORTED;
    ffb::Event event{};
    event.type = ffb::MessageType::EffectCommand;
    event.effect_kind = ffb::effect_kind_from_guid(m_guid);
    event.command = static_cast<std::uint16_t>(ffb::EffectCommand::Start);
    event.process_id = GetCurrentProcessId();
    event.device_id = m_device_id;
    event.effect_id = m_effect_id;
    event.effect_guid = m_guid;
    event.hresult = hr;
    event.flags = flags;
    event.iterations = iterations;
    ffb::Telemetry::instance().emit(event);
    return hr;
}

HRESULT STDMETHODCALLTYPE WrapperEffect::Stop() {
    const HRESULT hr = m_real ? m_real->Stop() : DIERR_UNSUPPORTED;
    ffb::Event event{};
    event.type = ffb::MessageType::EffectCommand;
    event.effect_kind = ffb::effect_kind_from_guid(m_guid);
    event.command = static_cast<std::uint16_t>(ffb::EffectCommand::Stop);
    event.process_id = GetCurrentProcessId();
    event.device_id = m_device_id;
    event.effect_id = m_effect_id;
    event.effect_guid = m_guid;
    event.hresult = hr;
    ffb::Telemetry::instance().emit(event);
    return hr;
}

HRESULT STDMETHODCALLTYPE WrapperEffect::GetEffectStatus(LPDWORD status) {
    return m_real ? m_real->GetEffectStatus(status) : DIERR_UNSUPPORTED;
}

HRESULT STDMETHODCALLTYPE WrapperEffect::Download() {
    const HRESULT hr = m_real ? m_real->Download() : DIERR_UNSUPPORTED;
    ffb::Event event{};
    event.type = ffb::MessageType::EffectCommand;
    event.effect_kind = ffb::effect_kind_from_guid(m_guid);
    event.command = static_cast<std::uint16_t>(ffb::EffectCommand::Download);
    event.process_id = GetCurrentProcessId();
    event.device_id = m_device_id;
    event.effect_id = m_effect_id;
    event.effect_guid = m_guid;
    event.hresult = hr;
    ffb::Telemetry::instance().emit(event);
    return hr;
}

HRESULT STDMETHODCALLTYPE WrapperEffect::Unload() {
    const HRESULT hr = m_real ? m_real->Unload() : DIERR_UNSUPPORTED;
    ffb::Event event{};
    event.type = ffb::MessageType::EffectCommand;
    event.effect_kind = ffb::effect_kind_from_guid(m_guid);
    event.command = static_cast<std::uint16_t>(ffb::EffectCommand::Unload);
    event.process_id = GetCurrentProcessId();
    event.device_id = m_device_id;
    event.effect_id = m_effect_id;
    event.effect_guid = m_guid;
    event.hresult = hr;
    ffb::Telemetry::instance().emit(event);
    return hr;
}

HRESULT STDMETHODCALLTYPE WrapperEffect::Escape(LPDIEFFESCAPE escape) {
    return m_real ? m_real->Escape(escape) : DIERR_UNSUPPORTED;
}
