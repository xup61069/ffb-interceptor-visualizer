// SPDX-License-Identifier: GPL-3.0-only
#include "pe_arch.h"

#include <windows.h>

namespace {

bool read_exact_at(HANDLE file, LONGLONG offset, void* destination,
                   DWORD size) noexcept {
    LARGE_INTEGER position{};
    position.QuadPart = offset;
    if (!SetFilePointerEx(file, position, nullptr, FILE_BEGIN)) return false;
    DWORD read = 0;
    return ReadFile(file, destination, size, &read, nullptr) && read == size;
}

}  // namespace

namespace ffb::launcher {

PeArchitecture read_pe_architecture(const std::wstring& path,
                                    std::wstring* error) noexcept {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE |
                                  FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        if (error) *error = L"無法讀取 PE 檔案。";
        return PeArchitecture::unknown;
    }

    LARGE_INTEGER size{};
    IMAGE_DOS_HEADER dos{};
    DWORD signature = 0;
    IMAGE_FILE_HEADER header{};
    const bool size_ok = GetFileSizeEx(file, &size) != FALSE;
    const bool dos_ok =
        read_exact_at(file, 0, &dos, static_cast<DWORD>(sizeof(dos)));
    bool header_ok = false;
    if (size_ok && dos_ok && dos.e_magic == IMAGE_DOS_SIGNATURE &&
        dos.e_lfanew >= static_cast<LONG>(sizeof(dos)) &&
        static_cast<LONGLONG>(dos.e_lfanew) +
                static_cast<LONGLONG>(sizeof(signature) + sizeof(header)) <=
            size.QuadPart) {
        header_ok = read_exact_at(file, dos.e_lfanew, &signature,
                                  static_cast<DWORD>(sizeof(signature))) &&
                    read_exact_at(file,
                                  dos.e_lfanew +
                                      static_cast<LONG>(sizeof(signature)),
                                  &header,
                                  static_cast<DWORD>(sizeof(header)));
    }
    CloseHandle(file);

    if (!header_ok || signature != IMAGE_NT_SIGNATURE) {
        if (error) *error = L"檔案不是有效的 Windows PE 執行檔。";
        return PeArchitecture::unknown;
    }
    if (header.Machine == IMAGE_FILE_MACHINE_I386) return PeArchitecture::x86;
    if (header.Machine == IMAGE_FILE_MACHINE_AMD64) return PeArchitecture::x64;
    if (error) *error = L"目前只支援 x86 與 x64 執行檔。";
    return PeArchitecture::unknown;
}

PeArchitecture current_architecture() noexcept {
#if defined(_WIN64)
    return PeArchitecture::x64;
#else
    return PeArchitecture::x86;
#endif
}

const wchar_t* architecture_name(PeArchitecture architecture) noexcept {
    switch (architecture) {
        case PeArchitecture::x86:
            return L"x86";
        case PeArchitecture::x64:
            return L"x64";
        default:
            return L"unknown";
    }
}

}  // namespace ffb::launcher
