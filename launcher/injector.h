// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <windows.h>

#include <string>
#include <vector>

namespace ffb::launcher {

struct LaunchRequest {
    std::wstring game_path;
    std::vector<std::wstring> game_arguments;
};

// Starts only a new, suspended child and initializes the fixed sibling hook.
// It intentionally exposes no existing-PID or arbitrary-DLL interface.
bool launch_offline_game(const LaunchRequest& request, DWORD* process_id,
                         std::wstring* error);

}  // namespace ffb::launcher
