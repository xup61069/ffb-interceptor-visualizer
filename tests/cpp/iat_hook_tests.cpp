// SPDX-License-Identifier: GPL-3.0-only
#undef NDEBUG
#include "iat_hook.h"

#include <windows.h>

#include <cassert>
#include <cstdint>
#include <cstring>

namespace {

constexpr std::size_t kImageSize = 4096;
constexpr DWORD kImportsRva = 0x200;
constexpr DWORD kLibraryNameRva = 0x300;
constexpr DWORD kLookupRva = 0x400;
constexpr DWORD kAddressesRva = 0x500;
constexpr DWORD kImportNameRva = 0x600;

DWORD WINAPI original_create(LPVOID) {
    return 1;
}

DWORD WINAPI replacement_create(LPVOID) {
    return 2;
}

struct TestImage {
    std::uint8_t* base = nullptr;

    TestImage() {
        base = static_cast<std::uint8_t*>(VirtualAlloc(
            nullptr, kImageSize, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE));
        assert(base != nullptr);
        std::memset(base, 0, kImageSize);

        auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
        dos->e_magic = IMAGE_DOS_SIGNATURE;
        dos->e_lfanew = 0x80;
        auto* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
        nt->Signature = IMAGE_NT_SIGNATURE;
        nt->OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR_MAGIC;
        nt->OptionalHeader.SizeOfImage = static_cast<DWORD>(kImageSize);
        nt->OptionalHeader.NumberOfRvaAndSizes = IMAGE_NUMBEROF_DIRECTORY_ENTRIES;
        nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT]
            .VirtualAddress = kImportsRva;
        nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].Size =
            2 * sizeof(IMAGE_IMPORT_DESCRIPTOR);

        auto* descriptor =
            reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + kImportsRva);
        descriptor->Name = kLibraryNameRva;
        descriptor->OriginalFirstThunk = kLookupRva;
        descriptor->FirstThunk = kAddressesRva;
        std::memcpy(base + kLibraryNameRva, "dinput8.dll", 12);

        auto* lookup =
            reinterpret_cast<IMAGE_THUNK_DATA*>(base + kLookupRva);
        lookup[0].u1.AddressOfData = kImportNameRva;
        auto* addresses =
            reinterpret_cast<IMAGE_THUNK_DATA*>(base + kAddressesRva);
        addresses[0].u1.Function = reinterpret_cast<ULONG_PTR>(&original_create);

        auto* import =
            reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + kImportNameRva);
        std::memcpy(import->Name, "DirectInput8Create", 19);
    }

    ~TestImage() {
        if (base) VirtualFree(base, 0, MEM_RELEASE);
    }

    void* address() const {
        const auto* addresses = reinterpret_cast<const IMAGE_THUNK_DATA*>(
            base + kAddressesRva);
        return reinterpret_cast<void*>(addresses[0].u1.Function);
    }
};

}  // namespace

int main() {
    TestImage named_import;
    assert(ffb::patch_direct_input8_imports(
               reinterpret_cast<HMODULE>(named_import.base),
               reinterpret_cast<void*>(&original_create),
               reinterpret_cast<void*>(&replacement_create)) == 1);
    assert(named_import.address() == reinterpret_cast<void*>(&replacement_create));

    // Re-running is idempotent and will not replace an already changed entry.
    assert(ffb::patch_direct_input8_imports(
               reinterpret_cast<HMODULE>(named_import.base),
               reinterpret_cast<void*>(&original_create),
               reinterpret_cast<void*>(&replacement_create)) == 0);

    // Some bound images omit OriginalFirstThunk.  In that case only the exact,
    // still-unmodified system function pointer is eligible for replacement.
    TestImage pointer_fallback;
    auto* descriptor = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(
        pointer_fallback.base + kImportsRva);
    descriptor->OriginalFirstThunk = 0;
    assert(ffb::patch_direct_input8_imports(
               reinterpret_cast<HMODULE>(pointer_fallback.base),
               reinterpret_cast<void*>(&original_create),
               reinterpret_cast<void*>(&replacement_create)) == 1);
    assert(pointer_fallback.address() ==
           reinterpret_cast<void*>(&replacement_create));

    TestImage unrelated_library;
    std::memcpy(unrelated_library.base + kLibraryNameRva, "notdinput.x", 12);
    assert(ffb::patch_direct_input8_imports(
               reinterpret_cast<HMODULE>(unrelated_library.base),
               reinterpret_cast<void*>(&original_create),
               reinterpret_cast<void*>(&replacement_create)) == 0);
    assert(unrelated_library.address() ==
           reinterpret_cast<void*>(&original_create));
    return 0;
}
