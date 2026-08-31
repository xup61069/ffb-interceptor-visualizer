// SPDX-License-Identifier: GPL-3.0-only
#include <windows.h>

#include <commctrl.h>
#include <commdlg.h>
#include <bcrypt.h>
#include <sddl.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <tlhelp32.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <string>
#include <utility>
#include <vector>

#include "manager_model.h"

#ifndef FFB_BUILD_VERSION
#define FFB_BUILD_VERSION "dev"
#endif

namespace {

constexpr wchar_t kWindowClass[] = L"FFBInterceptorManagerWindow";
constexpr wchar_t kWindowTitle[] = L"FFB Interceptor 即開即用管理器";
constexpr wchar_t kInstanceMutex[] =
    L"Local\\FFBInterceptor.OneClickManager.v1";
constexpr wchar_t kManagerInvocationEventPrefix[] =
    L"Local\\FFBInterceptor.ManagerElevation.v1.";

class ScopedHandle {
public:
    ScopedHandle() noexcept = default;
    explicit ScopedHandle(HANDLE value) noexcept : value_(value) {}
    ~ScopedHandle() { reset(); }
    ScopedHandle(const ScopedHandle&) = delete;
    ScopedHandle& operator=(const ScopedHandle&) = delete;
    HANDLE get() const noexcept { return value_; }
    explicit operator bool() const noexcept {
        return value_ && value_ != INVALID_HANDLE_VALUE;
    }
    void reset(HANDLE value = nullptr) noexcept {
        if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_);
        value_ = value;
    }
    HANDLE release() noexcept {
        HANDLE value = value_;
        value_ = nullptr;
        return value;
    }

private:
    HANDLE value_ = nullptr;
};

class ScopedLocalMemory {
public:
    ScopedLocalMemory() noexcept = default;
    explicit ScopedLocalMemory(HLOCAL value) noexcept : value_(value) {}
    ~ScopedLocalMemory() {
        if (value_) LocalFree(value_);
    }
    ScopedLocalMemory(const ScopedLocalMemory&) = delete;
    ScopedLocalMemory& operator=(const ScopedLocalMemory&) = delete;
    HLOCAL get() const noexcept { return value_; }

private:
    HLOCAL value_ = nullptr;
};

enum ControlId : int {
    kProfileCombo = 100,
    kNewProfile = 101,
    kSaveProfile = 102,
    kDeleteProfile = 103,
    kProfileName = 110,
    kGamePath = 120,
    kBrowseGame = 121,
    kGameArguments = 130,
    kSimHubPath = 140,
    kBrowseSimHub = 141,
    kAutoStartSimHub = 150,
    kCheckEnvironment = 160,
    kInstallPlugin = 161,
    kUninstallPlugin = 162,
    kLaunch = 163,
    kDiagnostics = 170,
    kCopyDiagnostics = 171
};

std::wstring utf8_literal_to_wide(const char* text) {
    const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                              text, -1, nullptr, 0);
    if (required <= 0) return L"dev";
    std::vector<wchar_t> result(static_cast<std::size_t>(required));
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1,
                        result.data(), required);
    return result.data();
}

std::wstring executable_path() {
    std::vector<wchar_t> buffer(MAX_PATH);
    for (;;) {
        const DWORD written = GetModuleFileNameW(
            nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
        if (written == 0) return {};
        if (written < buffer.size() - 1) {
            return std::wstring(buffer.data(), written);
        }
        if (buffer.size() >= 32768) return {};
        buffer.resize(buffer.size() * 2);
    }
}

std::wstring parent_path(const std::wstring& path) {
    const auto slash = path.find_last_of(L"\\/");
    return slash == std::wstring::npos ? std::wstring{} : path.substr(0, slash);
}

std::wstring join_path(const std::wstring& left, const std::wstring& right) {
    if (left.empty()) return right;
    if (left.back() == L'\\' || left.back() == L'/') return left + right;
    return left + L"\\" + right;
}

std::wstring file_name_without_extension(const std::wstring& path) {
    const auto slash = path.find_last_of(L"\\/");
    std::wstring name =
        slash == std::wstring::npos ? path : path.substr(slash + 1);
    const auto dot = name.find_last_of(L'.');
    if (dot != std::wstring::npos) name.resize(dot);
    return name;
}

std::wstring get_window_text(HWND window) {
    const int length = GetWindowTextLengthW(window);
    if (length <= 0) return {};
    std::vector<wchar_t> buffer(static_cast<std::size_t>(length) + 1);
    GetWindowTextW(window, buffer.data(), static_cast<int>(buffer.size()));
    return buffer.data();
}

void set_window_text(HWND window, const std::wstring& value) {
    SetWindowTextW(window, value.c_str());
}

bool process_running(const wchar_t* first, const wchar_t* second = nullptr) {
    HANDLE raw = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (raw == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    bool found = false;
    if (Process32FirstW(raw, &entry)) {
        do {
            if (_wcsicmp(entry.szExeFile, first) == 0 ||
                (second && _wcsicmp(entry.szExeFile, second) == 0)) {
                found = true;
                break;
            }
        } while (Process32NextW(raw, &entry));
    }
    CloseHandle(raw);
    return found;
}

std::wstring default_simhub_path() {
    for (const wchar_t* variable : {L"ProgramFiles(x86)", L"ProgramFiles"}) {
        const DWORD required = GetEnvironmentVariableW(variable, nullptr, 0);
        if (required == 0 || required > 32768) continue;
        std::vector<wchar_t> value(required);
        if (GetEnvironmentVariableW(variable, value.data(), required) == 0) {
            continue;
        }
        const std::wstring candidate = join_path(value.data(), L"SimHub");
        if (!ffb::manager::find_simhub_executable(candidate).empty()) {
            return candidate;
        }
    }
    return {};
}

bool select_game_file(HWND owner, std::wstring* selected) {
    wchar_t path[32768]{};
    OPENFILENAMEW dialog{};
    dialog.lStructSize = sizeof(dialog);
    dialog.hwndOwner = owner;
    dialog.lpstrFile = path;
    dialog.nMaxFile = static_cast<DWORD>(std::size(path));
    dialog.lpstrFilter = L"Windows 遊戲執行檔 (*.exe)\0*.exe\0所有檔案 (*.*)\0*.*\0";
    dialog.lpstrTitle = L"選擇要離線啟動的遊戲執行檔";
    dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST |
                   OFN_DONTADDTORECENT | OFN_NOCHANGEDIR;
    dialog.lpstrDefExt = L"exe";
    if (!GetOpenFileNameW(&dialog)) return false;
    *selected = path;
    return true;
}

bool select_directory(HWND owner, const std::wstring& initial,
                      std::wstring* selected) {
    IFileOpenDialog* dialog = nullptr;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) {
        return false;
    }
    DWORD options = 0;
    dialog->GetOptions(&options);
    dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                       FOS_PATHMUSTEXIST | FOS_DONTADDTORECENT);
    dialog->SetTitle(L"選擇 SimHub 安裝資料夾");
    if (!initial.empty()) {
        IShellItem* folder = nullptr;
        if (SUCCEEDED(SHCreateItemFromParsingName(
                initial.c_str(), nullptr, IID_PPV_ARGS(&folder)))) {
            dialog->SetFolder(folder);
            folder->Release();
        }
    }
    const HRESULT shown = dialog->Show(owner);
    if (FAILED(shown)) {
        dialog->Release();
        return false;
    }
    IShellItem* item = nullptr;
    PWSTR path = nullptr;
    const bool ok = SUCCEEDED(dialog->GetResult(&item)) &&
                    SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path));
    if (ok) *selected = path;
    if (path) CoTaskMemFree(path);
    if (item) item->Release();
    dialog->Release();
    return ok;
}

bool copy_to_clipboard(HWND owner, const std::wstring& text) {
    if (!OpenClipboard(owner)) return false;
    EmptyClipboard();
    const SIZE_T bytes = (text.size() + 1) * sizeof(wchar_t);
    HGLOBAL allocation = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!allocation) {
        CloseClipboard();
        return false;
    }
    void* destination = GlobalLock(allocation);
    if (!destination) {
        GlobalFree(allocation);
        CloseClipboard();
        return false;
    }
    memcpy(destination, text.c_str(), bytes);
    GlobalUnlock(allocation);
    if (!SetClipboardData(CF_UNICODETEXT, allocation)) {
        GlobalFree(allocation);
        CloseClipboard();
        return false;
    }
    CloseClipboard();
    return true;
}

bool pump_messages() {
    MSG message{};
    bool quit = false;
    WPARAM quit_code = 0;
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        if (message.message == WM_QUIT) {
            quit = true;
            quit_code = message.wParam;
            continue;
        }
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    if (quit) PostQuitMessage(static_cast<int>(quit_code));
    return !quit;
}

bool wait_for_process(HANDLE process, DWORD timeout_milliseconds,
                      DWORD* exit_code, bool* timed_out) {
    if (timed_out) *timed_out = false;
    const ULONGLONG deadline = GetTickCount64() + timeout_milliseconds;
    for (;;) {
        const DWORD remaining =
            GetTickCount64() >= deadline
                ? 0
                : static_cast<DWORD>(std::min<ULONGLONG>(
                      deadline - GetTickCount64(), 250));
        const DWORD waited = MsgWaitForMultipleObjects(
            1, &process, FALSE, remaining, QS_ALLINPUT);
        if (waited == WAIT_OBJECT_0) {
            DWORD result = 1;
            if (!GetExitCodeProcess(process, &result)) return false;
            if (exit_code) *exit_code = result;
            return true;
        }
        if (waited == WAIT_OBJECT_0 + 1 && !pump_messages()) return false;
        if (GetTickCount64() >= deadline) {
            if (timed_out) *timed_out = true;
            return false;
        }
        if (waited == WAIT_FAILED) return false;
    }
}

bool create_manager_invocation_event(ScopedHandle* event,
                                     std::wstring* event_name,
                                     std::wstring* error) {
    if (!event || !event_name) return false;
    event->reset();
    event_name->clear();
    PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
    // The UAC credential prompt can select a different administrator account.
    // The random name is not an authorization boundary, and the parent also
    // waits for the exact helper exit code, so grant authenticated users only
    // the two event rights needed for this cross-token synchronization.
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(A;;0x00100002;;;AU)(A;;GA;;;SY)",
            SDDL_REVISION_1, &raw_descriptor, nullptr)) {
        if (error) *error = L"Windows 無法建立提權同步物件的安全描述元。";
        return false;
    }
    ScopedLocalMemory descriptor(raw_descriptor);
    SECURITY_ATTRIBUTES security{};
    security.nLength = sizeof(security);
    security.lpSecurityDescriptor = descriptor.get();
    security.bInheritHandle = FALSE;
    constexpr wchar_t hex[] = L"0123456789ABCDEF";
    for (int attempt = 0; attempt < 4; ++attempt) {
        std::array<UCHAR, 32> entropy{};
        const NTSTATUS status = BCryptGenRandom(
            nullptr, entropy.data(), static_cast<ULONG>(entropy.size()),
            BCRYPT_USE_SYSTEM_PREFERRED_RNG);
        if (status < 0) {
            if (error) {
                *error = L"Windows 無法建立安全的 Manager 提權識別碼。";
            }
            return false;
        }
        std::wstring candidate = kManagerInvocationEventPrefix;
        candidate.reserve(candidate.size() + entropy.size() * 2);
        for (const UCHAR byte : entropy) {
            candidate.push_back(hex[(byte >> 4) & 0x0f]);
            candidate.push_back(hex[byte & 0x0f]);
        }
        SetLastError(ERROR_SUCCESS);
        ScopedHandle created(CreateEventExW(
            &security, candidate.c_str(), CREATE_EVENT_MANUAL_RESET,
            SYNCHRONIZE | EVENT_MODIFY_STATE));
        const DWORD create_error = GetLastError();
        if (created && create_error != ERROR_ALREADY_EXISTS) {
            event->reset(created.release());
            *event_name = std::move(candidate);
            return true;
        }
    }
    if (error) {
        *error = L"無法建立唯一的 Manager 提權同步物件。";
    }
    return false;
}

bool build_parameter_text(const std::vector<std::wstring>& arguments,
                          std::wstring* parameters, std::wstring* error) {
    if (!parameters) return false;
    parameters->clear();
    for (const auto& argument : arguments) {
        if (!parameters->empty()) parameters->push_back(L' ');
        *parameters += ffb::manager::quote_command_argument(argument);
        if (parameters->size() >= 32767) {
            parameters->clear();
            if (error) *error = L"命令列超過 Windows 長度上限。";
            return false;
        }
    }
    return true;
}

bool wait_for_elevated_process(HANDLE process, HANDLE invocation_event,
                               DWORD timeout_milliseconds, DWORD* exit_code,
                               bool* timed_out, bool* invocation_confirmed) {
    if (timed_out) *timed_out = false;
    if (invocation_confirmed) *invocation_confirmed = false;
    bool confirmed = false;
    const ULONGLONG deadline = GetTickCount64() + timeout_milliseconds;
    for (;;) {
        const ULONGLONG now = GetTickCount64();
        const DWORD remaining =
            now >= deadline
                ? 0
                : static_cast<DWORD>(std::min<ULONGLONG>(deadline - now, 250));
        HANDLE handles[2] = {process, invocation_event};
        const DWORD handle_count = confirmed ? 1U : 2U;
        const DWORD waited = MsgWaitForMultipleObjects(
            handle_count, handles, FALSE, remaining, QS_ALLINPUT);
        if (waited == WAIT_OBJECT_0) {
            if (!confirmed &&
                WaitForSingleObject(invocation_event, 0) == WAIT_OBJECT_0) {
                confirmed = true;
            }
            DWORD result = 1;
            if (!GetExitCodeProcess(process, &result)) return false;
            if (exit_code) *exit_code = result;
            if (invocation_confirmed) *invocation_confirmed = confirmed;
            return true;
        }
        if (!confirmed && waited == WAIT_OBJECT_0 + 1) {
            confirmed = true;
            continue;
        }
        if (waited == WAIT_OBJECT_0 + handle_count) {
            if (!pump_messages()) return false;
            continue;
        }
        if (GetTickCount64() >= deadline) {
            if (timed_out) *timed_out = true;
            if (invocation_confirmed) *invocation_confirmed = confirmed;
            return false;
        }
        if (waited == WAIT_FAILED) return false;
    }
}

bool run_elevated_process(HWND owner, const std::wstring& executable,
                          const std::wstring& working_directory,
                          const std::vector<std::wstring>& arguments,
                          HANDLE invocation_event,
                          DWORD timeout_milliseconds, DWORD* exit_code,
                          bool* timed_out, bool* process_may_be_running,
                          std::wstring* error) {
    if (process_may_be_running) *process_may_be_running = false;
    if (!invocation_event || invocation_event == INVALID_HANDLE_VALUE ||
        !ffb::manager::file_is_regular(executable) ||
        !ffb::manager::path_is_absolute_local(executable) ||
        !ffb::manager::path_is_absolute_local(working_directory)) {
        if (error) *error = L"原生 Manager helper 或提權同步物件無效。";
        return false;
    }
    std::wstring parameters;
    if (!build_parameter_text(arguments, &parameters, error)) return false;

    SHELLEXECUTEINFOW launch{};
    launch.cbSize = sizeof(launch);
    launch.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
    launch.hwnd = owner;
    launch.lpVerb = L"runas";
    launch.lpFile = executable.c_str();
    launch.lpParameters = parameters.c_str();
    launch.lpDirectory = working_directory.c_str();
    launch.nShow = SW_HIDE;
    if (!ShellExecuteExW(&launch) || !launch.hProcess) {
        const DWORD launch_error = GetLastError();
        if (launch.hProcess) CloseHandle(launch.hProcess);
        if (error) {
            *error = launch_error == ERROR_CANCELLED
                         ? L"已取消 Windows 系統管理員權限確認。"
                         : L"Windows 無法啟動受控的原生 Manager helper（錯誤 " +
                               std::to_wstring(launch_error) + L"）。";
        }
        return false;
    }

    ScopedHandle process(launch.hProcess);
    if (process_may_be_running) *process_may_be_running = true;
    bool invocation_confirmed = false;
    const bool waited = wait_for_elevated_process(
        process.get(), invocation_event, timeout_milliseconds, exit_code,
        timed_out, &invocation_confirmed);
    if (!waited) {
        if (error) {
            *error = timed_out && *timed_out
                         ? L"受控安裝程序未在安全等待時間內結束；本次管理器會保留套件鎖，請確認 PowerShell／UAC 視窗都已關閉後重新開啟管理器。"
                         : L"等待受控安裝程序時發生錯誤；本次管理器會保留套件鎖，請確認相關程序已關閉後重新開啟管理器。";
        }
        return false;
    }
    if (process_may_be_running) *process_may_be_running = false;
    if (!invocation_confirmed) {
        if (error) {
            *error = L"提升後的腳本未完成套件 handle、雜湊與簽章重驗，已拒絕接受結果。";
        }
        return false;
    }
    return true;
}

std::wstring system_directory_for_power_shell(
    const std::wstring& power_shell) {
    return parent_path(parent_path(parent_path(power_shell)));
}

bool run_sanitized_system_power_shell(
    const std::wstring& power_shell,
    const std::vector<std::wstring>& arguments, DWORD* exit_code,
    std::wstring* error) {
    std::wstring command = ffb::manager::quote_command_argument(power_shell);
    for (const auto& argument : arguments) {
        command.push_back(L' ');
        command += ffb::manager::quote_command_argument(argument);
    }
    if (command.size() >= 32767) {
        if (error) *error = L"受控 PowerShell 命令列超過 Windows 長度上限。";
        return false;
    }
    std::vector<wchar_t> environment;
    if (!ffb::manager::build_sanitized_powershell_environment(
            power_shell, &environment, error)) {
        return false;
    }
    std::vector<wchar_t> mutable_command(command.begin(), command.end());
    mutable_command.push_back(L'\0');
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION information{};
    const DWORD flags = CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT;
    const std::wstring working_directory = parent_path(power_shell);
    if (!CreateProcessW(
            power_shell.c_str(), mutable_command.data(), nullptr, nullptr,
            FALSE, flags, environment.data(), working_directory.c_str(),
            &startup, &information)) {
        if (error) {
            *error = L"Windows 無法以隔離環境啟動 System32 PowerShell（錯誤 " +
                     std::to_wstring(GetLastError()) + L"）。";
        }
        return false;
    }
    ScopedHandle process(information.hProcess);
    CloseHandle(information.hThread);
    if (WaitForSingleObject(process.get(), INFINITE) != WAIT_OBJECT_0) {
        // A valid process handle should always be waitable. If Windows cannot
        // wait, retain this helper (and its package lock) until the child is
        // observably gone instead of returning into a validation/use gap.
        DWORD observed = STILL_ACTIVE;
        do {
            Sleep(250);
        } while (!GetExitCodeProcess(process.get(), &observed) ||
                 observed == STILL_ACTIVE);
    }
    DWORD result = 1;
    if (!GetExitCodeProcess(process.get(), &result)) {
        if (error) *error = L"無法取得受控 PowerShell 的結束碼。";
        return false;
    }
    if (exit_code) *exit_code = result;
    return true;
}

int run_elevated_plugin_operation(
    const ffb::manager::ElevatedPluginRequest& request) {
    bool elevated = false;
    std::wstring error;
    if (!ffb::manager::query_current_process_elevation(&elevated, &error) ||
        !elevated) {
        return 1;
    }

    const std::wstring manager_path = executable_path();
    const std::wstring bundle_root =
        ffb::manager::locate_bundle_root(manager_path);
    const std::wstring expected_manager =
        join_path(bundle_root, L"FFBInterceptor.Manager.exe");
    if (manager_path.empty() || bundle_root.empty() ||
        _wcsicmp(manager_path.c_str(), expected_manager.c_str()) != 0) {
        return 1;
    }

    ScopedHandle invocation_event(OpenEventW(
        SYNCHRONIZE, FALSE, request.manager_invocation_event.c_str()));
    if (!invocation_event ||
        WaitForSingleObject(invocation_event.get(), 0) != WAIT_TIMEOUT) {
        return 1;
    }

    const auto layout = ffb::manager::make_package_layout(bundle_root);
    ffb::manager::PackageReadLock package_lock;
    if (!ffb::manager::acquire_package_read_lock(
            layout, &package_lock, &error)) {
        return 1;
    }
    const auto integrity = ffb::manager::verify_package_integrity(layout);
    const auto signature_policy = ffb::manager::build_signature_policy();
    const auto signatures = ffb::manager::verify_package_signatures(
        layout, manager_path, signature_policy);
    if (!integrity.valid || !signatures.allowed) return 1;

    const std::wstring& script =
        request.operation == ffb::manager::ElevatedPluginOperation::install
            ? layout.installer_script
            : layout.uninstaller_script;
    std::wstring power_shell;
    if (!ffb::manager::locate_system_windows_powershell(&power_shell,
                                                        &error)) {
        return 1;
    }
    std::vector<std::wstring> arguments = {
        L"-NoProfile", L"-NonInteractive", L"-ExecutionPolicy", L"Bypass",
        L"-File", script, L"-NoPause", L"-ManagerInvocationEvent",
        request.manager_invocation_event};
    if (request.operation ==
            ffb::manager::ElevatedPluginOperation::install &&
        !request.simhub_install_path.empty()) {
        arguments.push_back(L"-SimHubInstallPath");
        arguments.push_back(request.simhub_install_path);
    }
    DWORD child_exit_code = 1;
    if (!run_sanitized_system_power_shell(
            power_shell, arguments, &child_exit_code, &error)) {
        return 1;
    }
    return child_exit_code == 0 ? 0 : 1;
}

bool run_process(const std::wstring& executable,
                 const std::vector<std::wstring>& arguments,
                 DWORD timeout_milliseconds, bool no_window,
                 DWORD* exit_code, bool* timed_out,
                 bool* process_may_be_running, std::wstring* error) {
    if (process_may_be_running) *process_may_be_running = false;
    if (!ffb::manager::file_is_regular(executable)) {
        if (error) *error = L"找不到要執行的一般檔案：" + executable;
        return false;
    }
    std::wstring command = ffb::manager::quote_command_argument(executable);
    for (const auto& argument : arguments) {
        command.push_back(L' ');
        command += ffb::manager::quote_command_argument(argument);
    }
    if (command.size() >= 32767) {
        if (error) *error = L"命令列超過 Windows 長度上限。";
        return false;
    }
    std::vector<wchar_t> mutable_command(command.begin(), command.end());
    mutable_command.push_back(L'\0');
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION information{};
    const DWORD flags = no_window ? CREATE_NO_WINDOW : 0;
    const std::wstring working_directory = parent_path(executable);
    if (!CreateProcessW(executable.c_str(), mutable_command.data(), nullptr,
                        nullptr, FALSE, flags, nullptr,
                        working_directory.c_str(), &startup, &information)) {
        if (error) {
            *error = L"Windows 無法啟動程序（錯誤 " +
                     std::to_wstring(GetLastError()) + L"）。";
        }
        return false;
    }
    if (process_may_be_running) *process_may_be_running = true;
    CloseHandle(information.hThread);
    const bool waited = wait_for_process(information.hProcess,
                                         timeout_milliseconds, exit_code,
                                         timed_out);
    CloseHandle(information.hProcess);
    if (!waited) {
        if (error) {
            *error = timed_out && *timed_out
                         ? L"程序未在安全等待時間內結束；為避免安裝與解除安裝同時執行，本次管理器已鎖定變更操作。請確認 PowerShell／UAC 視窗都已關閉後重新開啟管理器。"
                         : L"等待程序時發生錯誤，程序可能仍在執行；本次管理器已鎖定變更操作。請確認相關程序已關閉後重新開啟管理器。";
        }
        return false;
    }
    if (process_may_be_running) *process_may_be_running = false;
    return true;
}

struct Readiness {
    bool package_ok = false;
    bool game_ok = false;
    bool simhub_installed = false;
    bool pipe_ready = false;
    bool elevated = false;
    bool privilege_ok = false;
    ffb::launcher::PeArchitecture game_arch =
        ffb::launcher::PeArchitecture::unknown;
    std::wstring simhub_executable;
    std::wstring text;
};

class ManagerWindow {
public:
    explicit ManagerWindow(HINSTANCE instance) : instance_(instance) {}

    bool create(int show_command) {
        WNDCLASSEXW window_class{};
        window_class.cbSize = sizeof(window_class);
        window_class.lpfnWndProc = &ManagerWindow::window_proc;
        window_class.hInstance = instance_;
        window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        window_class.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
        window_class.hbrBackground =
            reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
        window_class.lpszClassName = kWindowClass;
        if (!RegisterClassExW(&window_class) &&
            GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
            return false;
        }
        window_ = CreateWindowExW(
            0, kWindowClass, kWindowTitle,
            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
            CW_USEDEFAULT, CW_USEDEFAULT, 920, 780, nullptr, nullptr,
            instance_, this);
        if (!window_) return false;
        ShowWindow(window_, show_command);
        UpdateWindow(window_);
        return true;
    }

private:
    static LRESULT CALLBACK window_proc(HWND window, UINT message,
                                        WPARAM wparam, LPARAM lparam) {
        ManagerWindow* self = reinterpret_cast<ManagerWindow*>(
            GetWindowLongPtrW(window, GWLP_USERDATA));
        if (message == WM_NCCREATE) {
            const auto* creation =
                reinterpret_cast<const CREATESTRUCTW*>(lparam);
            self = static_cast<ManagerWindow*>(creation->lpCreateParams);
            self->window_ = window;
            SetWindowLongPtrW(window, GWLP_USERDATA,
                              reinterpret_cast<LONG_PTR>(self));
        }
        return self ? self->handle_message(message, wparam, lparam)
                    : DefWindowProcW(window, message, wparam, lparam);
    }

    LRESULT handle_message(UINT message, WPARAM wparam, LPARAM lparam) {
        switch (message) {
            case WM_CREATE:
                initialize_controls();
                return initialize_state() ? 0 : -1;
            case WM_COMMAND:
                handle_command(LOWORD(wparam), HIWORD(wparam),
                               reinterpret_cast<HWND>(lparam));
                return 0;
            case WM_CLOSE:
                if (!busy_) DestroyWindow(window_);
                return 0;
            case WM_DESTROY:
                if (font_) DeleteObject(font_);
                PostQuitMessage(0);
                return 0;
            default:
                return DefWindowProcW(window_, message, wparam, lparam);
        }
    }

    HWND add_control(const wchar_t* class_name, const wchar_t* text,
                     DWORD style, int x, int y, int width, int height,
                     int id, DWORD extended_style = 0) {
        HWND control = CreateWindowExW(
            extended_style, class_name, text,
            WS_CHILD | WS_VISIBLE | style, x, y, width, height, window_,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), instance_,
            nullptr);
        if (control && font_) {
            SendMessageW(control, WM_SETFONT,
                         reinterpret_cast<WPARAM>(font_), TRUE);
        }
        return control;
    }

    void add_label(const wchar_t* text, int x, int y, int width,
                   int height = 24) {
        add_control(L"STATIC", text, SS_LEFT, x, y, width, height, 0);
    }

    void initialize_controls() {
        font_ = CreateFontW(-18, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                            CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                            DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
        add_label(L"FFB Interceptor 即開即用管理器", 24, 18, 500, 30);
        add_label(L"只建立你選定的新遊戲程序，不會修改遊戲資料夾，也不會處理已在執行的程序。",
                  24, 50, 850, 26);

        add_label(L"遊戲設定檔", 24, 88, 120);
        profile_combo_ = add_control(
            L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP, 145, 84, 390,
            300, kProfileCombo);
        add_control(L"BUTTON", L"新增", BS_PUSHBUTTON | WS_TABSTOP, 545, 83,
                    90, 30, kNewProfile);
        add_control(L"BUTTON", L"儲存", BS_PUSHBUTTON | WS_TABSTOP, 643, 83,
                    90, 30, kSaveProfile);
        add_control(L"BUTTON", L"刪除", BS_PUSHBUTTON | WS_TABSTOP, 741, 83,
                    90, 30, kDeleteProfile);

        add_label(L"顯示名稱", 24, 128, 120);
        name_edit_ = add_control(L"EDIT", L"", WS_BORDER | ES_AUTOHSCROLL |
                                                   WS_TABSTOP,
                                 145, 124, 686, 28, kProfileName,
                                 WS_EX_CLIENTEDGE);

        add_label(L"遊戲 EXE", 24, 168, 120);
        game_edit_ = add_control(L"EDIT", L"", WS_BORDER | ES_AUTOHSCROLL |
                                                   WS_TABSTOP,
                                 145, 164, 590, 28, kGamePath,
                                 WS_EX_CLIENTEDGE);
        add_control(L"BUTTON", L"瀏覽…", BS_PUSHBUTTON | WS_TABSTOP, 741, 163,
                    90, 30, kBrowseGame);

        add_label(L"遊戲參數", 24, 208, 120);
        arguments_edit_ = add_control(
            L"EDIT", L"", WS_BORDER | ES_AUTOHSCROLL | WS_TABSTOP, 145, 204,
            686, 28, kGameArguments, WS_EX_CLIENTEDGE);

        add_label(L"SimHub 資料夾", 24, 248, 120);
        simhub_edit_ = add_control(L"EDIT", L"", WS_BORDER | ES_AUTOHSCROLL |
                                                     WS_TABSTOP,
                                   145, 244, 590, 28, kSimHubPath,
                                   WS_EX_CLIENTEDGE);
        add_control(L"BUTTON", L"瀏覽…", BS_PUSHBUTTON | WS_TABSTOP, 741, 243,
                    90, 30, kBrowseSimHub);
        auto_start_checkbox_ = add_control(
            L"BUTTON", L"一鍵啟動時自動開啟 SimHub", BS_AUTOCHECKBOX | WS_TABSTOP,
            145, 280, 360, 28, kAutoStartSimHub);

        add_control(L"BUTTON", L"檢查環境", BS_PUSHBUTTON | WS_TABSTOP, 24, 322,
                    145, 36, kCheckEnvironment);
        add_control(L"BUTTON", L"安裝／更新插件", BS_PUSHBUTTON | WS_TABSTOP,
                    178, 322, 165, 36, kInstallPlugin);
        add_control(L"BUTTON", L"解除安裝插件", BS_PUSHBUTTON | WS_TABSTOP,
                    352, 322, 165, 36, kUninstallPlugin);
        add_control(L"BUTTON", L"一鍵啟動", BS_DEFPUSHBUTTON | WS_TABSTOP, 658,
                    318, 173, 44, kLaunch);

        add_label(L"環境診斷", 24, 380, 150);
        add_control(L"BUTTON", L"複製診斷資訊", BS_PUSHBUTTON | WS_TABSTOP, 674,
                    374, 157, 32, kCopyDiagnostics);
        diagnostics_edit_ = add_control(
            L"EDIT", L"尚未檢查。",
            WS_BORDER | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY |
                WS_VSCROLL,
            24, 412, 807, 285, kDiagnostics, WS_EX_CLIENTEDGE);

        add_label(L"第一次安裝後，請在 SimHub〈設定 → 插件〉啟用 FFB Interceptor；之後即可直接按「一鍵啟動」。",
                  24, 712, 850, 28);
        SendMessageW(auto_start_checkbox_, BM_SETCHECK, BST_CHECKED, 0);
    }

    bool initialize_state() {
        executable_path_ = executable_path();
        bundle_root_ = ffb::manager::locate_bundle_root(executable_path_);
        layout_ = ffb::manager::make_package_layout(bundle_root_);
        std::wstring error;
        std::wstring active_id;
        if (!store_.load(&profiles_, &active_id, &error)) {
            MessageBoxW(window_, error.c_str(), L"設定讀取失敗",
                        MB_OK | MB_ICONERROR);
            return false;
        }
        if (profiles_.empty()) {
            ffb::manager::Profile profile{};
            profile.id = ffb::manager::ProfileStore::create_id();
            profile.name = L"我的離線遊戲";
            profile.simhub_path = default_simhub_path();
            if (profile.id.empty() || !store_.save(profile, true, &error)) {
                if (error.empty()) error = L"Windows 無法建立設定檔識別碼。";
                MessageBoxW(window_, error.c_str(), L"設定建立失敗",
                            MB_OK | MB_ICONERROR);
                return false;
            }
            profiles_.push_back(profile);
            active_id = profile.id;
        }
        refresh_profile_combo(active_id);
        update_diagnostics(collect_readiness());
        return true;
    }

    void refresh_profile_combo(const std::wstring& selected_id) {
        SendMessageW(profile_combo_, CB_RESETCONTENT, 0, 0);
        int selected = 0;
        for (std::size_t index = 0; index < profiles_.size(); ++index) {
            SendMessageW(profile_combo_, CB_ADDSTRING, 0,
                         reinterpret_cast<LPARAM>(profiles_[index].name.c_str()));
            if (_wcsicmp(profiles_[index].id.c_str(), selected_id.c_str()) == 0) {
                selected = static_cast<int>(index);
            }
        }
        SendMessageW(profile_combo_, CB_SETCURSEL, selected, 0);
        current_index_ = static_cast<std::size_t>(selected);
        load_profile_to_form(profiles_[current_index_]);
    }

    void load_profile_to_form(const ffb::manager::Profile& profile) {
        set_window_text(name_edit_, profile.name);
        set_window_text(game_edit_, profile.game_path);
        set_window_text(arguments_edit_, profile.game_arguments);
        set_window_text(simhub_edit_, profile.simhub_path);
        SendMessageW(auto_start_checkbox_, BM_SETCHECK,
                     profile.auto_start_simhub ? BST_CHECKED : BST_UNCHECKED,
                     0);
    }

    ffb::manager::Profile profile_from_form() const {
        ffb::manager::Profile profile = profiles_[current_index_];
        profile.name = get_window_text(name_edit_);
        profile.game_path = get_window_text(game_edit_);
        profile.game_arguments = get_window_text(arguments_edit_);
        profile.simhub_path = get_window_text(simhub_edit_);
        profile.auto_start_simhub =
            SendMessageW(auto_start_checkbox_, BM_GETCHECK, 0, 0) == BST_CHECKED;
        return profile;
    }

    bool save_current(bool notify) {
        auto profile = profile_from_form();
        if (profile.name.empty()) {
            MessageBoxW(window_, L"請先輸入設定檔顯示名稱。", L"無法儲存",
                        MB_OK | MB_ICONWARNING);
            return false;
        }
        std::wstring error;
        if (!store_.save(profile, true, &error)) {
            MessageBoxW(window_, error.c_str(), L"儲存失敗",
                        MB_OK | MB_ICONERROR);
            return false;
        }
        profiles_[current_index_] = profile;
        SendMessageW(profile_combo_, CB_DELETESTRING,
                     static_cast<WPARAM>(current_index_), 0);
        SendMessageW(profile_combo_, CB_INSERTSTRING,
                     static_cast<WPARAM>(current_index_),
                     reinterpret_cast<LPARAM>(profile.name.c_str()));
        SendMessageW(profile_combo_, CB_SETCURSEL,
                     static_cast<WPARAM>(current_index_), 0);
        if (notify) {
            MessageBoxW(window_, L"已儲存；設定只包含路徑與啟動偏好。",
                        L"儲存完成", MB_OK | MB_ICONINFORMATION);
        }
        return true;
    }

    bool installed_plugins_match(const ffb::manager::Profile& profile,
                                 std::wstring* detail) const {
        if (profile.simhub_path.empty()) {
            if (detail) *detail = L"尚未選擇 SimHub 資料夾。";
            return false;
        }
        const std::wstring destination_core =
            join_path(profile.simhub_path, L"FFBInterceptor.Core.dll");
        const std::wstring destination_plugin =
            join_path(profile.simhub_path, L"FFBInterceptor.SimHub.dll");
        for (const auto& pair :
             {std::pair<std::wstring, std::wstring>{layout_.simhub_core,
                                                    destination_core},
              std::pair<std::wstring, std::wstring>{layout_.simhub_plugin,
                                                    destination_plugin}}) {
            std::wstring source_hash;
            std::wstring destination_hash;
            std::wstring error;
            if (!ffb::manager::file_sha256(pair.first, &source_hash, &error) ||
                !ffb::manager::file_sha256(pair.second, &destination_hash,
                                           &error)) {
                if (detail) *detail = L"插件檔案缺少或不是一般檔案。";
                return false;
            }
            if (_wcsicmp(source_hash.c_str(), destination_hash.c_str()) != 0) {
                if (detail) *detail = L"已安裝插件與這個套件的版本不一致。";
                return false;
            }
        }
        if (detail) *detail = L"已安裝插件與套件雜湊一致。";
        return true;
    }

    Readiness collect_readiness() const {
        Readiness result{};
        const auto profile = profile_from_form();
        std::wstring report;
        report += L"FFB Interceptor 管理器版本：" +
                  utf8_literal_to_wide(FFB_BUILD_VERSION) + L"\r\n";
        report += L"套件根目錄：" +
                  (bundle_root_.empty() ? L"（找不到）" : bundle_root_) +
                  L"\r\n\r\n";

        const auto integrity =
            ffb::manager::verify_package_integrity(layout_);
        result.package_ok = integrity.valid;
        if (integrity.valid) {
            report += L"[正常] 套件 manifest 已逐檔驗證，共 " +
                      std::to_wstring(integrity.verified_files) + L" 個檔案。\r\n";
        } else {
            report += L"[錯誤] 套件完整性驗證失敗，已禁止啟動。\r\n";
            for (const auto& issue : integrity.issues) {
                report += L"        " + issue.relative_path + L"：" +
                          issue.detail + L"\r\n";
            }
        }

        const auto signature_policy =
            ffb::manager::build_signature_policy();
        const auto signatures = ffb::manager::verify_package_signatures(
            layout_, executable_path_, signature_policy);
        if (signature_policy.required) {
            if (signatures.allowed) {
                report += L"[正常] 穩定版必要檔案皆具 Windows 受信任簽章，且簽署者一致。\r\n";
            } else {
                result.package_ok = false;
                report += L"[錯誤] 穩定版簽章政策未通過，已禁止安裝與啟動。\r\n";
                for (const auto& issue : signatures.issues) {
                    report += L"        " + issue.relative_path + L"：" +
                              issue.detail + L"\r\n";
                }
            }
        } else {
            report += L"[注意] 這是實驗版建置：未強制程式碼簽章，請只使用 GitHub Actions attestation 已驗證的官方套件。\r\n";
        }

        std::wstring elevation_error;
        if (!ffb::manager::query_current_process_elevation(
                &result.elevated, &elevation_error)) {
            result.elevated = true;
            report += L"[錯誤] " + elevation_error +
                      L" 為安全起見已禁止啟動。\r\n";
        } else {
            result.privilege_ok = !result.elevated;
            report += result.elevated
                          ? L"[錯誤] 管理器正以系統管理員身分執行；請關閉後正常開啟。\r\n"
                          : L"[正常] 管理器使用一般使用者權限。\r\n";
        }

        std::wstring architecture_error;
        if (!ffb::manager::path_is_absolute_local(profile.game_path)) {
            architecture_error = L"請選擇本機磁碟上的遊戲 EXE，不能使用網路路徑。";
        } else {
            result.game_arch = ffb::launcher::read_pe_architecture(
                profile.game_path, &architecture_error);
        }
        if (result.game_arch == ffb::launcher::PeArchitecture::unknown) {
            report += L"[錯誤] 遊戲 EXE 無法使用：" + architecture_error +
                      L"\r\n";
        } else {
            const std::wstring launcher =
                ffb::manager::launcher_path_for(layout_, result.game_arch);
            const std::wstring hook =
                ffb::manager::hook_path_for(layout_, result.game_arch);
            std::wstring launcher_error;
            std::wstring hook_error;
            const bool launcher_ok =
                ffb::launcher::read_pe_architecture(launcher, &launcher_error) ==
                result.game_arch;
            const bool hook_ok =
                ffb::launcher::read_pe_architecture(hook, &hook_error) ==
                result.game_arch;
            result.game_ok = launcher_ok && hook_ok;
            report += result.game_ok
                          ? L"[正常] 遊戲與固定 Launcher/Hook 架構一致："
                          : L"[錯誤] 套件缺少與遊戲相符的 Launcher/Hook：";
            report += ffb::launcher::architecture_name(result.game_arch);
            report += L"\r\n";
            if (result.game_ok) {
                report += L"[正常] 使用固定 Hook 啟動模式，不會把 dinput8.dll 寫進遊戲資料夾。\r\n";
            }
        }

        if (ffb::manager::path_is_absolute_local(profile.simhub_path)) {
            result.simhub_executable =
                ffb::manager::find_simhub_executable(profile.simhub_path);
        }
        if (result.simhub_executable.empty()) {
            report += ffb::manager::path_is_absolute_local(profile.simhub_path)
                          ? L"[錯誤] 指定資料夾內找不到 SimHubWPF.exe 或 SimHub.exe。\r\n"
                          : L"[錯誤] SimHub 必須位於本機磁碟的絕對路徑。\r\n";
        } else {
            report += L"[正常] 找到 SimHub：" + result.simhub_executable + L"\r\n";
        }
        std::wstring plugin_detail;
        result.simhub_installed = installed_plugins_match(profile, &plugin_detail);
        report += result.simhub_installed ? L"[正常] " : L"[注意] ";
        report += plugin_detail + L"\r\n";
        result.pipe_ready = ffb::manager::simhub_pipe_ready(0);
        report += result.pipe_ready
                      ? L"[正常] SimHub 插件管線已就緒。\r\n"
                      : L"[注意] SimHub 插件管線尚未就緒；請啟動 SimHub 並啟用插件。\r\n";
        report += L"\r\n隱私：複製診斷時會把使用者家目錄改成 %USERPROFILE%。";
        result.text = report;
        return result;
    }

    void update_diagnostics(const Readiness& readiness) {
        last_diagnostics_ = readiness.text;
        set_window_text(diagnostics_edit_, last_diagnostics_);
    }

    void set_busy(bool busy) {
        busy_ = busy;
        for (const int id : {kProfileCombo, kProfileName, kGamePath,
                             kGameArguments, kSimHubPath, kAutoStartSimHub,
                             kNewProfile, kSaveProfile, kDeleteProfile,
                             kBrowseGame, kBrowseSimHub, kCheckEnvironment,
                             kInstallPlugin, kUninstallPlugin, kLaunch}) {
            EnableWindow(GetDlgItem(window_, id), busy ? FALSE : TRUE);
        }
        if (!busy && operation_in_doubt_) {
            for (const int id : {kInstallPlugin, kUninstallPlugin, kLaunch}) {
                EnableWindow(GetDlgItem(window_, id), FALSE);
            }
        }
        SetCursor(LoadCursorW(nullptr, busy ? IDC_WAIT : IDC_ARROW));
    }

    bool run_script(const std::wstring& script,
                    const ffb::manager::Profile& profile,
                    DWORD* exit_code) {
        const bool is_installer =
            _wcsicmp(script.c_str(), layout_.installer_script.c_str()) == 0;
        const bool is_uninstaller =
            _wcsicmp(script.c_str(), layout_.uninstaller_script.c_str()) == 0;
        if (!is_installer && !is_uninstaller) {
            MessageBoxW(window_, L"Manager 僅允許提升固定的安裝或解除安裝腳本。",
                        L"已阻止提權", MB_OK | MB_ICONERROR);
            return false;
        }
        bool elevated = false;
        std::wstring elevation_error;
        if (!ffb::manager::query_current_process_elevation(
                &elevated, &elevation_error) ||
            elevated) {
            const std::wstring permission_message =
                elevated
                    ? L"管理器不能以系統管理員身分執行安裝或解除安裝；請關閉後正常開啟。"
                    : L"無法確認管理器權限，已拒絕執行腳本：" +
                          elevation_error;
            MessageBoxW(window_, permission_message.c_str(),
                        L"權限安全檢查失敗", MB_OK | MB_ICONERROR);
            return false;
        }
        ffb::manager::PackageReadLock package_lock;
        std::wstring error;
        if (!ffb::manager::acquire_package_read_lock(
                layout_, &package_lock, &error)) {
            MessageBoxW(window_,
                        (L"無法鎖定套件以避免驗證後遭替換：" + error).c_str(),
                        L"套件安全鎖失敗", MB_OK | MB_ICONERROR);
            return false;
        }
        const auto integrity =
            ffb::manager::verify_package_integrity(layout_);
        const auto signature_policy =
            ffb::manager::build_signature_policy();
        const auto signatures = ffb::manager::verify_package_signatures(
            layout_, executable_path_, signature_policy);
        if (!integrity.valid || !signatures.allowed) {
            MessageBoxW(window_,
                        L"執行前重新驗證套件時，完整性或穩定版簽章政策未通過，已取消操作。",
                        L"套件信任驗證失敗", MB_OK | MB_ICONERROR);
            return false;
        }
        std::wstring power_shell;
        if (!ffb::manager::locate_system_windows_powershell(&power_shell,
                                                            &error)) {
            MessageBoxW(window_, error.c_str(), L"System32 驗證失敗",
                        MB_OK | MB_ICONERROR);
            return false;
        }
        const std::wstring system_directory =
            system_directory_for_power_shell(power_shell);
        ScopedHandle invocation_event;
        std::wstring invocation_event_name;
        if (!create_manager_invocation_event(
                &invocation_event, &invocation_event_name, &error)) {
            MessageBoxW(window_, error.c_str(), L"提權同步失敗",
                        MB_OK | MB_ICONERROR);
            return false;
        }
        std::vector<std::wstring> arguments = {
            L"--elevated-plugin-op", is_installer ? L"install" : L"uninstall",
            L"--manager-invocation-event", invocation_event_name};
        if (!profile.simhub_path.empty() && is_installer) {
            arguments.push_back(L"--simhub-install-path");
            arguments.push_back(profile.simhub_path);
        }
        bool timed_out = false;
        bool process_may_be_running = false;
        if (!run_elevated_process(
                window_, executable_path_, system_directory, arguments,
                invocation_event.get(), 10U * 60U * 1000U, exit_code, &timed_out,
                &process_may_be_running, &error)) {
            if (process_may_be_running) {
                operation_in_doubt_ = true;
                in_doubt_package_lock_ = std::move(package_lock);
            }
            MessageBoxW(window_, error.c_str(), L"安裝程序失敗",
                        MB_OK | MB_ICONERROR);
            return false;
        }
        return true;
    }

    bool install_plugin(bool allow_upgrade_retry) {
        const auto readiness = collect_readiness();
        update_diagnostics(readiness);
        if (!readiness.package_ok) {
            MessageBoxW(window_,
                        L"套件完整性未通過，為安全起見不會執行安裝腳本。",
                        L"已阻止安裝", MB_OK | MB_ICONERROR);
            return false;
        }
        if (!readiness.privilege_ok) {
            MessageBoxW(window_,
                        L"管理器權限安全檢查未通過；請關閉後以一般使用者權限重新開啟。",
                        L"已阻止安裝", MB_OK | MB_ICONERROR);
            return false;
        }
        const auto profile = profile_from_form();
        if (readiness.simhub_executable.empty()) {
            MessageBoxW(window_, L"請先選擇正確的 SimHub 安裝資料夾。",
                        L"缺少 SimHub", MB_OK | MB_ICONWARNING);
            return false;
        }
        if (process_running(L"SimHub.exe", L"SimHubWPF.exe")) {
            MessageBoxW(window_, L"請先關閉 SimHub，再安裝或更新插件。",
                        L"SimHub 正在執行", MB_OK | MB_ICONWARNING);
            return false;
        }
        DWORD exit_code = 1;
        set_busy(true);
        const bool invoked = run_script(layout_.installer_script, profile,
                                        &exit_code);
        set_busy(false);
        if (operation_in_doubt_) return false;
        if (invoked && exit_code == 0) {
            update_diagnostics(collect_readiness());
            MessageBoxW(window_,
                        L"插件已安全安裝／更新。接著請開啟 SimHub，並在「設定 → 插件」啟用 FFB Interceptor。",
                        L"安裝完成", MB_OK | MB_ICONINFORMATION);
            return true;
        }
        if (operation_in_doubt_) return false;
        if (allow_upgrade_retry &&
            MessageBoxW(window_,
                        L"安裝器未完成。若這台電腦有受管理的舊版，可先安全解除安裝（會還原原檔）再重試。現在要執行嗎？",
                        L"嘗試安全升級", MB_YESNO | MB_ICONQUESTION) == IDYES) {
            DWORD uninstall_exit = 1;
            set_busy(true);
            const bool removed = run_script(layout_.uninstaller_script, profile,
                                            &uninstall_exit);
            set_busy(false);
            if (removed && uninstall_exit == 0) {
                return install_plugin(false);
            }
        }
        MessageBoxW(window_,
                    (L"插件安裝未完成（結束碼 " +
                     std::to_wstring(exit_code) + L"）。診斷區保留目前狀態。")
                        .c_str(),
                    L"安裝失敗", MB_OK | MB_ICONERROR);
        return false;
    }

    bool ensure_pipe(const Readiness& initial) {
        if (initial.pipe_ready) return true;
        const auto profile = profile_from_form();
        if (!profile.auto_start_simhub || initial.simhub_executable.empty()) {
            return false;
        }
        SHELLEXECUTEINFOW launch{};
        launch.cbSize = sizeof(launch);
        launch.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
        launch.hwnd = window_;
        launch.lpFile = initial.simhub_executable.c_str();
        const std::wstring directory = parent_path(initial.simhub_executable);
        launch.lpDirectory = directory.c_str();
        launch.nShow = SW_SHOWNORMAL;
        if (!ShellExecuteExW(&launch)) return false;
        if (launch.hProcess) CloseHandle(launch.hProcess);

        set_busy(true);
        const ULONGLONG deadline = GetTickCount64() + 30000;
        bool ready = false;
        while (GetTickCount64() < deadline) {
            if (ffb::manager::simhub_pipe_ready(250)) {
                ready = true;
                break;
            }
            if (!pump_messages()) break;
        }
        set_busy(false);
        return ready;
    }

    void launch_game() {
        if (!save_current(false)) return;
        Readiness readiness = collect_readiness();
        update_diagnostics(readiness);
        if (!readiness.package_ok || !readiness.privilege_ok ||
            !readiness.game_ok) {
            MessageBoxW(window_,
                        L"尚有會影響安全啟動的錯誤，請先依診斷區修正。",
                        L"無法啟動", MB_OK | MB_ICONERROR);
            return;
        }
        if (!readiness.simhub_installed) {
            if (MessageBoxW(window_,
                            L"SimHub 插件尚未安裝或版本不同。要先執行安全安裝／更新嗎？",
                            L"需要安裝插件",
                            MB_YESNO | MB_ICONQUESTION) != IDYES ||
                !install_plugin(true)) {
                return;
            }
            readiness = collect_readiness();
            update_diagnostics(readiness);
        }
        if (!ensure_pipe(readiness)) {
            update_diagnostics(collect_readiness());
            MessageBoxW(window_,
                        L"SimHub 插件管線尚未就緒。請在 SimHub「設定 → 插件」啟用 FFB Interceptor；這是第一次唯一需要手動完成的步驟。",
                        L"等待 SimHub 設定", MB_OK | MB_ICONWARNING);
            return;
        }

        const auto profile = profile_from_form();
        std::vector<std::wstring> game_arguments;
        std::wstring error;
        if (!ffb::manager::split_game_arguments(profile.game_arguments,
                                                &game_arguments, &error)) {
            MessageBoxW(window_, error.c_str(), L"遊戲參數錯誤",
                        MB_OK | MB_ICONERROR);
            return;
        }
        std::vector<std::wstring> arguments = {L"--offline-only", L"--game",
                                               profile.game_path, L"--"};
        arguments.insert(arguments.end(), game_arguments.begin(),
                         game_arguments.end());
        const std::wstring launcher =
            ffb::manager::launcher_path_for(layout_, readiness.game_arch);
        ffb::manager::PackageReadLock package_lock;
        if (!ffb::manager::acquire_package_read_lock(
                layout_, &package_lock, &error)) {
            MessageBoxW(window_,
                        (L"無法鎖定套件以避免驗證後遭替換：" + error).c_str(),
                        L"套件安全鎖失敗", MB_OK | MB_ICONERROR);
            return;
        }
        const auto final_integrity =
            ffb::manager::verify_package_integrity(layout_);
        const auto signature_policy =
            ffb::manager::build_signature_policy();
        const auto final_signatures = ffb::manager::verify_package_signatures(
            layout_, executable_path_, signature_policy);
        if (!final_integrity.valid || !final_signatures.allowed) {
            update_diagnostics(collect_readiness());
            MessageBoxW(window_,
                        L"即將啟動前，套件完整性或穩定版簽章政策未通過，已取消操作。",
                        L"套件信任驗證失敗", MB_OK | MB_ICONERROR);
            return;
        }
        DWORD exit_code = 1;
        bool timed_out = false;
        bool process_may_be_running = false;
        set_busy(true);
        const bool launched = run_process(launcher, arguments, 120000, false,
                                          &exit_code, &timed_out,
                                          &process_may_be_running, &error);
        if (process_may_be_running) {
            operation_in_doubt_ = true;
            in_doubt_package_lock_ = std::move(package_lock);
        }
        set_busy(false);
        if (!launched || exit_code != 0) {
            if (launched) {
                error = L"離線啟動器回報錯誤（結束碼 " +
                        std::to_wstring(exit_code) + L"）。";
            }
            MessageBoxW(window_, error.c_str(), L"遊戲啟動失敗",
                        MB_OK | MB_ICONERROR);
            return;
        }
        MessageBoxW(window_,
                    L"遊戲已透過固定 Hook 安全啟動；遊戲資料夾沒有被修改。",
                    L"啟動完成", MB_OK | MB_ICONINFORMATION);
    }

    void handle_command(int id, int notification, HWND) {
        if (busy_) return;
        if (id == kProfileCombo && notification == CBN_SELCHANGE) {
            const LRESULT selected =
                SendMessageW(profile_combo_, CB_GETCURSEL, 0, 0);
            if (selected >= 0 &&
                static_cast<std::size_t>(selected) < profiles_.size()) {
                auto previous = profile_from_form();
                if (previous.name.empty()) {
                    SendMessageW(profile_combo_, CB_SETCURSEL,
                                 static_cast<WPARAM>(current_index_), 0);
                    MessageBoxW(window_, L"請先輸入目前設定檔的顯示名稱。",
                                L"無法切換設定檔", MB_OK | MB_ICONWARNING);
                    return;
                }
                const bool renamed =
                    previous.name != profiles_[current_index_].name;
                std::wstring save_error;
                if (!store_.save(previous, false, &save_error)) {
                    SendMessageW(profile_combo_, CB_SETCURSEL,
                                 static_cast<WPARAM>(current_index_), 0);
                    MessageBoxW(window_, save_error.c_str(), L"自動儲存失敗",
                                MB_OK | MB_ICONERROR);
                    return;
                }
                profiles_[current_index_] = std::move(previous);
                if (renamed) {
                    SendMessageW(profile_combo_, CB_DELETESTRING,
                                 static_cast<WPARAM>(current_index_), 0);
                    SendMessageW(
                        profile_combo_, CB_INSERTSTRING,
                        static_cast<WPARAM>(current_index_),
                        reinterpret_cast<LPARAM>(
                            profiles_[current_index_].name.c_str()));
                }
                current_index_ = static_cast<std::size_t>(selected);
                SendMessageW(profile_combo_, CB_SETCURSEL,
                             static_cast<WPARAM>(current_index_), 0);
                load_profile_to_form(profiles_[current_index_]);
                std::wstring active_error;
                if (!store_.set_active(profiles_[current_index_].id,
                                       &active_error)) {
                    MessageBoxW(window_, active_error.c_str(),
                                L"切換設定檔失敗", MB_OK | MB_ICONERROR);
                }
                update_diagnostics(collect_readiness());
            }
            return;
        }
        switch (id) {
            case kNewProfile: {
                if (profiles_.size() >= 64) {
                    MessageBoxW(window_, L"最多可儲存 64 個遊戲設定檔。",
                                L"設定檔已達上限", MB_OK | MB_ICONWARNING);
                    break;
                }
                if (!save_current(false)) break;
                ffb::manager::Profile profile{};
                profile.id = ffb::manager::ProfileStore::create_id();
                profile.name = L"新的離線遊戲";
                profile.simhub_path = get_window_text(simhub_edit_);
                std::wstring save_error;
                if (profile.id.empty() ||
                    !store_.save(profile, true, &save_error)) {
                    if (save_error.empty()) {
                        save_error = L"Windows 無法建立設定檔識別碼。";
                    }
                    MessageBoxW(window_, save_error.c_str(), L"新增失敗",
                                MB_OK | MB_ICONERROR);
                    break;
                }
                profiles_.push_back(profile);
                current_index_ = profiles_.size() - 1;
                refresh_profile_combo(profile.id);
                SetFocus(game_edit_);
                break;
            }
            case kSaveProfile:
                save_current(true);
                break;
            case kDeleteProfile: {
                if (MessageBoxW(window_, L"確定刪除目前的遊戲設定檔嗎？",
                                L"刪除設定檔",
                                MB_YESNO | MB_ICONQUESTION) != IDYES) {
                    break;
                }
                std::wstring erase_error;
                if (!store_.erase(profiles_[current_index_].id,
                                  &erase_error)) {
                    MessageBoxW(window_, erase_error.c_str(), L"刪除失敗",
                                MB_OK | MB_ICONERROR);
                    break;
                }
                profiles_.erase(profiles_.begin() +
                                static_cast<std::ptrdiff_t>(current_index_));
                if (profiles_.empty()) {
                    ffb::manager::Profile profile{};
                    profile.id = ffb::manager::ProfileStore::create_id();
                    profile.name = L"我的離線遊戲";
                    profile.simhub_path = default_simhub_path();
                    std::wstring save_error;
                    if (profile.id.empty() ||
                        !store_.save(profile, true, &save_error)) {
                        if (save_error.empty()) {
                            save_error = L"Windows 無法建立設定檔識別碼。";
                        }
                        MessageBoxW(window_, save_error.c_str(),
                                    L"建立預設設定失敗",
                                    MB_OK | MB_ICONERROR);
                        DestroyWindow(window_);
                        break;
                    }
                    profiles_.push_back(profile);
                }
                refresh_profile_combo(profiles_.front().id);
                std::wstring active_error;
                if (!store_.set_active(profiles_.front().id, &active_error)) {
                    MessageBoxW(window_, active_error.c_str(),
                                L"更新使用中設定失敗",
                                MB_OK | MB_ICONERROR);
                }
                break;
            }
            case kBrowseGame: {
                std::wstring selected;
                if (select_game_file(window_, &selected)) {
                    set_window_text(game_edit_, selected);
                    const std::wstring current_name = get_window_text(name_edit_);
                    if (current_name == L"我的離線遊戲" ||
                        current_name == L"新的離線遊戲") {
                        set_window_text(name_edit_,
                                        file_name_without_extension(selected));
                    }
                    update_diagnostics(collect_readiness());
                }
                break;
            }
            case kBrowseSimHub: {
                std::wstring selected;
                if (select_directory(window_, get_window_text(simhub_edit_),
                                     &selected)) {
                    set_window_text(simhub_edit_, selected);
                    update_diagnostics(collect_readiness());
                }
                break;
            }
            case kCheckEnvironment:
                save_current(false);
                update_diagnostics(collect_readiness());
                break;
            case kInstallPlugin:
                if (save_current(false)) install_plugin(true);
                break;
            case kUninstallPlugin: {
                if (!save_current(false)) break;
                const auto readiness = collect_readiness();
                update_diagnostics(readiness);
                if (!readiness.package_ok) {
                    MessageBoxW(window_,
                                L"套件完整性未通過，不會執行解除安裝腳本。",
                                L"已阻止操作", MB_OK | MB_ICONERROR);
                    break;
                }
                if (!readiness.privilege_ok) {
                    MessageBoxW(window_,
                                L"管理器權限安全檢查未通過；請關閉後以一般使用者權限重新開啟。",
                                L"已阻止操作", MB_OK | MB_ICONERROR);
                    break;
                }
                if (process_running(L"SimHub.exe", L"SimHubWPF.exe")) {
                    MessageBoxW(window_, L"請先關閉 SimHub，再解除安裝插件。",
                                L"SimHub 正在執行", MB_OK | MB_ICONWARNING);
                    break;
                }
                if (MessageBoxW(window_,
                                L"解除安裝只會移除受管理的插件並還原先前備份；匯入的 Dashboard 會保留。確定繼續嗎？",
                                L"安全解除安裝",
                                MB_YESNO | MB_ICONQUESTION) != IDYES) {
                    break;
                }
                DWORD exit_code = 1;
                set_busy(true);
                const bool invoked = run_script(layout_.uninstaller_script,
                                                profile_from_form(),
                                                &exit_code);
                set_busy(false);
                update_diagnostics(collect_readiness());
                MessageBoxW(window_,
                            invoked && exit_code == 0
                                ? L"受管理的 SimHub 插件已安全解除安裝。"
                                : L"解除安裝未完成，未確認的檔案不會被刪除。",
                            L"解除安裝",
                            MB_OK | (invoked && exit_code == 0
                                         ? MB_ICONINFORMATION
                                         : MB_ICONERROR));
                break;
            }
            case kLaunch:
                launch_game();
                break;
            case kCopyDiagnostics: {
                const std::wstring redacted =
                    ffb::manager::redact_user_path(last_diagnostics_);
                if (copy_to_clipboard(window_, redacted)) {
                    MessageBoxW(window_,
                                L"已複製去識別化診斷資訊，可直接貼到 GitHub Issue。",
                                L"複製完成", MB_OK | MB_ICONINFORMATION);
                }
                break;
            }
            default:
                break;
        }
    }

    HINSTANCE instance_ = nullptr;
    HWND window_ = nullptr;
    HFONT font_ = nullptr;
    HWND profile_combo_ = nullptr;
    HWND name_edit_ = nullptr;
    HWND game_edit_ = nullptr;
    HWND arguments_edit_ = nullptr;
    HWND simhub_edit_ = nullptr;
    HWND auto_start_checkbox_ = nullptr;
    HWND diagnostics_edit_ = nullptr;
    bool busy_ = false;
    bool operation_in_doubt_ = false;
    ffb::manager::ProfileStore store_;
    ffb::manager::PackageReadLock in_doubt_package_lock_;
    std::vector<ffb::manager::Profile> profiles_;
    std::size_t current_index_ = 0;
    std::wstring executable_path_;
    std::wstring bundle_root_;
    ffb::manager::PackageLayout layout_;
    std::wstring last_diagnostics_;
};

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int show_command) {
    int raw_argument_count = 0;
    LPWSTR* raw_arguments = CommandLineToArgvW(
        GetCommandLineW(), &raw_argument_count);
    if (!raw_arguments || raw_argument_count < 1) {
        if (raw_arguments) LocalFree(raw_arguments);
        return 1;
    }
    std::vector<std::wstring> arguments;
    arguments.reserve(static_cast<std::size_t>(raw_argument_count - 1));
    for (int index = 1; index < raw_argument_count; ++index) {
        arguments.emplace_back(raw_arguments[index]);
    }
    LocalFree(raw_arguments);
    ffb::manager::ElevatedPluginRequest elevated_request{};
    std::wstring elevated_request_error;
    const auto elevated_parse = ffb::manager::parse_elevated_plugin_request(
        arguments, &elevated_request, &elevated_request_error);
    if (elevated_parse == ffb::manager::ElevatedPluginParseResult::invalid) {
        return 1;
    }
    if (elevated_parse == ffb::manager::ElevatedPluginParseResult::valid) {
        return run_elevated_plugin_operation(elevated_request);
    }

    HANDLE instance_mutex = CreateMutexW(nullptr, FALSE, kInstanceMutex);
    const DWORD mutex_error = GetLastError();
    if (!instance_mutex || mutex_error == ERROR_ALREADY_EXISTS) {
        if (instance_mutex) CloseHandle(instance_mutex);
        MessageBoxW(nullptr,
                    mutex_error == ERROR_ALREADY_EXISTS
                        ? L"已有一個 FFB Interceptor 管理器正在執行。"
                        : L"無法建立管理器的單一執行個體安全鎖。",
                    L"無法啟動", MB_OK | MB_ICONERROR);
        return 1;
    }
    const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED |
                                                   COINIT_DISABLE_OLE1DDE);
    if (FAILED(com)) {
        CloseHandle(instance_mutex);
        MessageBoxW(nullptr, L"無法初始化 Windows COM 元件。", L"啟動失敗",
                    MB_OK | MB_ICONERROR);
        return 1;
    }
    INITCOMMONCONTROLSEX controls{};
    controls.dwSize = sizeof(controls);
    controls.dwICC = ICC_STANDARD_CLASSES;
    InitCommonControlsEx(&controls);

    ManagerWindow manager(instance);
    if (!manager.create(show_command)) {
        MessageBoxW(nullptr, L"無法建立 FFB Interceptor 管理器視窗。",
                    L"啟動失敗", MB_OK | MB_ICONERROR);
        CoUninitialize();
        CloseHandle(instance_mutex);
        return 1;
    }
    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    CoUninitialize();
    CloseHandle(instance_mutex);
    return static_cast<int>(message.wParam);
}
