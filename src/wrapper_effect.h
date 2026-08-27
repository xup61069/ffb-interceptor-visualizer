// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Valmantas Paliksa
#pragma once

#include <windows.h>
#include <dinput.h>
#include <cstdint>

class WrapperEffect final : public IDirectInputEffect {
public:
    WrapperEffect(IDirectInputEffect* real, std::uint32_t device_id,
                  std::uint32_t effect_id, REFGUID effect_guid);
    ~WrapperEffect();

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, void**) override;
    ULONG STDMETHODCALLTYPE AddRef() override;
    ULONG STDMETHODCALLTYPE Release() override;
    HRESULT STDMETHODCALLTYPE Initialize(HINSTANCE, DWORD, REFGUID) override;
    HRESULT STDMETHODCALLTYPE GetEffectGuid(LPGUID) override;
    HRESULT STDMETHODCALLTYPE GetParameters(LPDIEFFECT, DWORD) override;
    HRESULT STDMETHODCALLTYPE SetParameters(LPCDIEFFECT, DWORD) override;
    HRESULT STDMETHODCALLTYPE Start(DWORD, DWORD) override;
    HRESULT STDMETHODCALLTYPE Stop() override;
    HRESULT STDMETHODCALLTYPE GetEffectStatus(LPDWORD) override;
    HRESULT STDMETHODCALLTYPE Download() override;
    HRESULT STDMETHODCALLTYPE Unload() override;
    HRESULT STDMETHODCALLTYPE Escape(LPDIEFFESCAPE) override;

private:
    IDirectInputEffect* m_real = nullptr;
    GUID m_guid{};
    std::uint32_t m_device_id = 0;
    std::uint32_t m_effect_id = 0;
    volatile LONG m_ref_count = 1;
};
