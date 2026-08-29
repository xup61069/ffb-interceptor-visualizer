// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <string>

namespace ffb::launcher {

enum class PeArchitecture { unknown, x86, x64 };

PeArchitecture read_pe_architecture(const std::wstring& path,
                                    std::wstring* error) noexcept;
PeArchitecture current_architecture() noexcept;
const wchar_t* architecture_name(PeArchitecture architecture) noexcept;

}  // namespace ffb::launcher
