// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Valmantas Paliksa
#pragma once

#include <windows.h>
#include <dinput.h>
#include <cstdint>
#include <type_traits>

template<bool Unicode>
class WrapperDevice8 final
    : public std::conditional_t<Unicode, IDirectInputDevice8W, IDirectInputDevice8A> {
public:
    using Base = std::conditional_t<Unicode, IDirectInputDevice8W, IDirectInputDevice8A>;
    using Char = std::conditional_t<Unicode, wchar_t, char>;
    using DevInstT = std::conditional_t<Unicode, DIDEVICEINSTANCEW, DIDEVICEINSTANCEA>;
    using DevObjInstT = std::conditional_t<Unicode, DIDEVICEOBJECTINSTANCEW, DIDEVICEOBJECTINSTANCEA>;
    using EffInfoT = std::conditional_t<Unicode, DIEFFECTINFOW, DIEFFECTINFOA>;
    using ActFmtT = std::conditional_t<Unicode, DIACTIONFORMATW, DIACTIONFORMATA>;
    using EnumObjCbT = std::conditional_t<Unicode, LPDIENUMDEVICEOBJECTSCALLBACKW, LPDIENUMDEVICEOBJECTSCALLBACKA>;
    using EnumFxCbT = std::conditional_t<Unicode, LPDIENUMEFFECTSCALLBACKW, LPDIENUMEFFECTSCALLBACKA>;
    using EnumSemCbT = std::conditional_t<Unicode, LPDIENUMDEVICESBYSEMANTICSCBW, LPDIENUMDEVICESBYSEMANTICSCBA>;

    WrapperDevice8(Base* real, std::uint32_t device_id);
    ~WrapperDevice8();

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, void**) override;
    ULONG STDMETHODCALLTYPE AddRef() override;
    ULONG STDMETHODCALLTYPE Release() override;
    HRESULT STDMETHODCALLTYPE GetCapabilities(LPDIDEVCAPS) override;
    HRESULT STDMETHODCALLTYPE EnumObjects(EnumObjCbT, LPVOID, DWORD) override;
    HRESULT STDMETHODCALLTYPE GetProperty(REFGUID, LPDIPROPHEADER) override;
    HRESULT STDMETHODCALLTYPE SetProperty(REFGUID, LPCDIPROPHEADER) override;
    HRESULT STDMETHODCALLTYPE Acquire() override;
    HRESULT STDMETHODCALLTYPE Unacquire() override;
    HRESULT STDMETHODCALLTYPE GetDeviceState(DWORD, LPVOID) override;
    HRESULT STDMETHODCALLTYPE GetDeviceData(DWORD, LPDIDEVICEOBJECTDATA, LPDWORD, DWORD) override;
    HRESULT STDMETHODCALLTYPE SetDataFormat(LPCDIDATAFORMAT) override;
    HRESULT STDMETHODCALLTYPE SetEventNotification(HANDLE) override;
    HRESULT STDMETHODCALLTYPE SetCooperativeLevel(HWND, DWORD) override;
    HRESULT STDMETHODCALLTYPE GetObjectInfo(DevObjInstT*, DWORD, DWORD) override;
    HRESULT STDMETHODCALLTYPE GetDeviceInfo(DevInstT*) override;
    HRESULT STDMETHODCALLTYPE RunControlPanel(HWND, DWORD) override;
    HRESULT STDMETHODCALLTYPE Initialize(HINSTANCE, DWORD, REFGUID) override;
    HRESULT STDMETHODCALLTYPE CreateEffect(REFGUID, LPCDIEFFECT, LPDIRECTINPUTEFFECT*, LPUNKNOWN) override;
    HRESULT STDMETHODCALLTYPE EnumEffects(EnumFxCbT, LPVOID, DWORD) override;
    HRESULT STDMETHODCALLTYPE GetEffectInfo(EffInfoT*, REFGUID) override;
    HRESULT STDMETHODCALLTYPE GetForceFeedbackState(LPDWORD) override;
    HRESULT STDMETHODCALLTYPE SendForceFeedbackCommand(DWORD) override;
    HRESULT STDMETHODCALLTYPE EnumCreatedEffectObjects(LPDIENUMCREATEDEFFECTOBJECTSCALLBACK, LPVOID, DWORD) override;
    HRESULT STDMETHODCALLTYPE Escape(LPDIEFFESCAPE) override;
    HRESULT STDMETHODCALLTYPE Poll() override;
    HRESULT STDMETHODCALLTYPE SendDeviceData(DWORD, LPCDIDEVICEOBJECTDATA, LPDWORD, DWORD) override;
    HRESULT STDMETHODCALLTYPE BuildActionMap(ActFmtT*, const Char*, DWORD) override;
    HRESULT STDMETHODCALLTYPE SetActionMap(ActFmtT*, const Char*, DWORD) override;
    HRESULT STDMETHODCALLTYPE GetImageInfo(std::conditional_t<Unicode, LPDIDEVICEIMAGEINFOHEADERW, LPDIDEVICEIMAGEINFOHEADERA>) override;
    HRESULT STDMETHODCALLTYPE EnumEffectsInFile(const Char*, LPDIENUMEFFECTSINFILECALLBACK, LPVOID, DWORD) override;
    HRESULT STDMETHODCALLTYPE WriteEffectToFile(const Char*, DWORD, LPDIFILEEFFECT, DWORD) override;

private:
    Base* m_real = nullptr;
    std::uint32_t m_device_id = 0;
    volatile LONG m_ref_count = 1;
};

using WrapperDevice8A = WrapperDevice8<false>;
using WrapperDevice8W = WrapperDevice8<true>;
