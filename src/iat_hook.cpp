// SPDX-License-Identifier: GPL-3.0-only
#include "iat_hook.h"

#include <tlhelp32.h>

#include <cstdint>
#include <cstring>

namespace {

bool range_is_valid(std::size_t image_size, std::size_t rva,
                    std::size_t length) noexcept {
    return rva < image_size && length <= image_size - rva;
}

bool bounded_ascii_equal_ci(const char* value, std::size_t available,
                            const char* expected) noexcept {
    if (!value || !expected) return false;
    for (std::size_t index = 0; index < available; ++index) {
        const auto left = static_cast<unsigned char>(value[index]);
        const auto right = static_cast<unsigned char>(expected[index]);
        if (left == 0 || right == 0) return left == right;
        const auto folded_left =
            left >= 'A' && left <= 'Z' ? static_cast<unsigned char>(left + 32)
                                      : left;
        const auto folded_right =
            right >= 'A' && right <= 'Z'
                ? static_cast<unsigned char>(right + 32)
                : right;
        if (folded_left != folded_right) return false;
    }
    return false;
}

bool patch_pointer(void** slot, void* original, void* replacement) noexcept {
    if (!slot || !original || !replacement || original == replacement) {
        return false;
    }

    DWORD old_protection = 0;
    if (!VirtualProtect(slot, sizeof(*slot), PAGE_READWRITE, &old_protection)) {
        return false;
    }

    auto* volatile_slot = reinterpret_cast<PVOID volatile*>(slot);
    const auto observed = InterlockedCompareExchangePointer(
        volatile_slot, replacement, original);

    DWORD ignored = 0;
    VirtualProtect(slot, sizeof(*slot), old_protection, &ignored);
    return observed == original;
}

std::size_t patch_import_descriptor(std::uint8_t* base,
                                    std::size_t image_size,
                                    const IMAGE_IMPORT_DESCRIPTOR& descriptor,
                                    void* original,
                                    void* replacement) noexcept {
    if (!range_is_valid(image_size, descriptor.FirstThunk,
                        sizeof(IMAGE_THUNK_DATA))) {
        return 0;
    }

    const DWORD lookup_rva = descriptor.OriginalFirstThunk;
    const auto maximum_entries =
        (image_size - static_cast<std::size_t>(descriptor.FirstThunk)) /
        sizeof(IMAGE_THUNK_DATA);
    auto* addresses = reinterpret_cast<IMAGE_THUNK_DATA*>(
        base + descriptor.FirstThunk);
    auto* lookups = lookup_rva == 0
                        ? nullptr
                        : reinterpret_cast<IMAGE_THUNK_DATA*>(base + lookup_rva);

    std::size_t patched = 0;
    for (std::size_t index = 0; index < maximum_entries; ++index) {
        const auto address_rva =
            static_cast<std::size_t>(descriptor.FirstThunk) +
            index * sizeof(IMAGE_THUNK_DATA);
        if (!range_is_valid(image_size, address_rva,
                            sizeof(IMAGE_THUNK_DATA))) {
            break;
        }

        auto* slot = reinterpret_cast<void**>(&addresses[index].u1.Function);
        if (!lookups) {
            if (*slot == nullptr) break;
            if (patch_pointer(slot, original, replacement)) ++patched;
            continue;
        }

        const auto lookup_entry_rva =
            static_cast<std::size_t>(lookup_rva) +
            index * sizeof(IMAGE_THUNK_DATA);
        if (!range_is_valid(image_size, lookup_entry_rva,
                            sizeof(IMAGE_THUNK_DATA))) {
            break;
        }

        const auto lookup = lookups[index].u1.Ordinal;
        if (lookup == 0) break;
        if (IMAGE_SNAP_BY_ORDINAL(lookup)) continue;

        const auto name_rva =
            static_cast<std::size_t>(lookups[index].u1.AddressOfData);
        if (!range_is_valid(image_size, name_rva,
                            sizeof(IMAGE_IMPORT_BY_NAME))) {
            continue;
        }
        const auto* import = reinterpret_cast<const IMAGE_IMPORT_BY_NAME*>(
            base + name_rva);
        const auto import_name_rva =
            name_rva + offsetof(IMAGE_IMPORT_BY_NAME, Name);
        if (import_name_rva >= image_size) continue;
        if (!bounded_ascii_equal_ci(
                reinterpret_cast<const char*>(import->Name),
                image_size - import_name_rva, "DirectInput8Create")) {
            continue;
        }
        if (patch_pointer(slot, original, replacement)) ++patched;
    }
    return patched;
}

}  // namespace

namespace ffb {

std::size_t patch_direct_input8_imports(HMODULE module, void* original,
                                        void* replacement) noexcept {
    if (!module || !original || !replacement) return 0;

    auto* base = reinterpret_cast<std::uint8_t*>(module);
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 ||
        dos->e_lfanew > 1024 * 1024) {
        return 0;
    }

    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(
        base + static_cast<std::size_t>(dos->e_lfanew));
    if (nt->Signature != IMAGE_NT_SIGNATURE ||
        nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR_MAGIC) {
        return 0;
    }

    const auto image_size =
        static_cast<std::size_t>(nt->OptionalHeader.SizeOfImage);
    if (image_size < sizeof(IMAGE_DOS_HEADER) ||
        static_cast<std::size_t>(dos->e_lfanew) + sizeof(*nt) > image_size) {
        return 0;
    }

    const auto& directory =
        nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (directory.VirtualAddress == 0 ||
        directory.Size < sizeof(IMAGE_IMPORT_DESCRIPTOR) ||
        !range_is_valid(image_size, directory.VirtualAddress,
                        directory.Size)) {
        return 0;
    }

    const auto* descriptors = reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR*>(
        base + directory.VirtualAddress);
    const auto descriptor_count =
        directory.Size / sizeof(IMAGE_IMPORT_DESCRIPTOR);
    std::size_t patched = 0;
    for (std::size_t index = 0; index < descriptor_count; ++index) {
        const auto& descriptor = descriptors[index];
        if (descriptor.Name == 0 && descriptor.FirstThunk == 0) break;
        if (!range_is_valid(image_size, descriptor.Name, 1)) continue;
        const auto* library_name =
            reinterpret_cast<const char*>(base + descriptor.Name);
        if (!bounded_ascii_equal_ci(
                library_name,
                image_size - static_cast<std::size_t>(descriptor.Name),
                "dinput8.dll")) {
            continue;
        }
        if (descriptor.OriginalFirstThunk != 0 &&
            !range_is_valid(image_size, descriptor.OriginalFirstThunk,
                            sizeof(IMAGE_THUNK_DATA))) {
            continue;
        }
        patched += patch_import_descriptor(base, image_size, descriptor,
                                           original, replacement);
    }
    return patched;
}

std::size_t patch_loaded_direct_input_imports(HMODULE excluded_module,
                                              void* original,
                                              void* replacement) noexcept {
    HANDLE snapshot = CreateToolhelp32Snapshot(
        TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, GetCurrentProcessId());
    if (snapshot == INVALID_HANDLE_VALUE) return 0;

    MODULEENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    std::size_t patched = 0;
    if (Module32FirstW(snapshot, &entry)) {
        do {
            const auto module = reinterpret_cast<HMODULE>(entry.modBaseAddr);
            if (module != excluded_module) {
                HMODULE pinned_module = nullptr;
                if (GetModuleHandleExW(
                        GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                        reinterpret_cast<LPCWSTR>(module), &pinned_module)) {
                    patched += patch_direct_input8_imports(
                        pinned_module, original, replacement);
                    FreeLibrary(pinned_module);
                }
            }
            entry.dwSize = sizeof(entry);
        } while (Module32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);
    return patched;
}

}  // namespace ffb
