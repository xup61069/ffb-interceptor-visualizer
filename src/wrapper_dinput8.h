// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Valmantas Paliksa
#pragma once

#include <windows.h>
#include <dinput.h>
#include <type_traits>

struct WrapperDirectInput8State;

template<bool Unicode>
class WrapperDirectInput8 final
    : public std::conditional_t<Unicode, IDirectInput8W, IDirectInput8A> {
public:
    using Base = std::conditional_t<Unicode, IDirectInput8W, IDirectInput8A>;
    using Char = std::conditional_t<Unicode, wchar_t, char>;
    using DevIfaceT = std::conditional_t<Unicode, IDirectInputDevice8W, IDirectInputDevice8A>;
    using EnumDevCbT = std::conditional_t<Unicode, LPDIENUMDEVICESCALLBACKW, LPDIENUMDEVICESCALLBACKA>;
    using ActFmtT = std::conditional_t<Unicode, DIACTIONFORMATW, DIACTIONFORMATA>;
    using EnumSemCbT = std::conditional_t<Unicode, LPDIENUMDEVICESBYSEMANTICSCBW, LPDIENUMDEVICESBYSEMANTICSCBA>;
    using CfgDevParamsT = std::conditional_t<Unicode, DICONFIGUREDEVICESPARAMSW, DICONFIGUREDEVICESPARAMSA>;

    explicit WrapperDirectInput8(Base* real);
    ~WrapperDirectInput8();
    bool valid() const noexcept { return m_state != nullptr; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, void**) override;
    ULONG STDMETHODCALLTYPE AddRef() override;
    ULONG STDMETHODCALLTYPE Release() override;
    HRESULT STDMETHODCALLTYPE CreateDevice(REFGUID, DevIfaceT**, LPUNKNOWN) override;
    HRESULT STDMETHODCALLTYPE EnumDevices(DWORD, EnumDevCbT, LPVOID, DWORD) override;
    HRESULT STDMETHODCALLTYPE GetDeviceStatus(REFGUID) override;
    HRESULT STDMETHODCALLTYPE RunControlPanel(HWND, DWORD) override;
    HRESULT STDMETHODCALLTYPE Initialize(HINSTANCE, DWORD) override;
    HRESULT STDMETHODCALLTYPE FindDevice(REFGUID, const Char*, LPGUID) override;
    HRESULT STDMETHODCALLTYPE EnumDevicesBySemantics(const Char*, ActFmtT*, EnumSemCbT, LPVOID, DWORD) override;
    HRESULT STDMETHODCALLTYPE ConfigureDevices(LPDICONFIGUREDEVICESCALLBACK, CfgDevParamsT*, DWORD, LPVOID) override;

private:
    friend struct WrapperDirectInput8State;
    template<bool>
    friend class WrapperDirectInput8;
    WrapperDirectInput8(WrapperDirectInput8State* state, Base* real);

    Base* m_real = nullptr;
    WrapperDirectInput8State* m_state = nullptr;
};

using WrapperDirectInput8A = WrapperDirectInput8<false>;
using WrapperDirectInput8W = WrapperDirectInput8<true>;
