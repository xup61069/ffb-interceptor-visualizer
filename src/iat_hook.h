// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <windows.h>

#include <cstddef>

namespace ffb {

// Replaces an unmodified dinput8!DirectInput8Create IAT entry in one mapped
// module.  The function deliberately refuses to overwrite an entry that was
// already changed by another component.
std::size_t patch_direct_input8_imports(HMODULE module, void* original,
                                        void* replacement) noexcept;

// Applies the same restricted patch to modules already loaded in this process.
std::size_t patch_loaded_direct_input_imports(HMODULE excluded_module,
                                              void* original,
                                              void* replacement) noexcept;

}  // namespace ffb
