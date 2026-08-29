// SPDX-License-Identifier: GPL-3.0-only
#include "injector.h"

#include <algorithm>
#include <cstdint>
#include <cwchar>
#include <limits>
#include <string>
#include <vector>

#include "pe_arch.h"

namespace {

constexpr DWORD kRemoteCallTimeoutMs = 15000;
constexpr DWORD kStartupTimeoutMs = 15000;
constexpr wchar_t kHookFileName[] = L"FFBInterceptor.Hook.dll";

class UniqueHandle {
public:
    UniqueHandle() noexcept = default;
    explicit UniqueHandle(HANDLE value) noexcept : value_(value) {}
    ~UniqueHandle() { reset(); }
    UniqueHandle(const UniqueHandle&) = delete;
    UniqueHandle& operator=(const UniqueHandle&) = delete;
    UniqueHandle(UniqueHandle&& other) noexcept : value_(other.release()) {}
    UniqueHandle& operator=(UniqueHandle&& other) noexcept {
        if (this != &other) reset(other.release());
        return *this;
    }
    HANDLE get() const noexcept { return value_; }
    explicit operator bool() const noexcept {
        return value_ && value_ != INVALID_HANDLE_VALUE;
    }
    HANDLE release() noexcept {
        HANDLE value = value_;
        value_ = nullptr;
        return value;
    }
    void reset(HANDLE value = nullptr) noexcept {
        if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_);
        value_ = value;
    }

private:
    HANDLE value_ = nullptr;
};

class SuspendedChild {
public:
    explicit SuspendedChild(PROCESS_INFORMATION information) noexcept
        : information_(information) {}
    ~SuspendedChild() {
        if (!released_ && information_.hProcess) {
            TerminateProcess(information_.hProcess, ERROR_CANCELLED);
            WaitForSingleObject(information_.hProcess, 5000);
        }
        if (information_.hThread) CloseHandle(information_.hThread);
        if (information_.hProcess) CloseHandle(information_.hProcess);
    }
    SuspendedChild(const SuspendedChild&) = delete;
    SuspendedChild& operator=(const SuspendedChild&) = delete;
    HANDLE process() const noexcept { return information_.hProcess; }
    HANDLE thread() const noexcept { return information_.hThread; }
    DWORD process_id() const noexcept { return information_.dwProcessId; }
    void release() noexcept { released_ = true; }

private:
    PROCESS_INFORMATION information_{};
    bool released_ = false;
};

class RemoteAllocation {
public:
    RemoteAllocation(HANDLE process, SIZE_T size) noexcept : process_(process) {
        address_ = VirtualAllocEx(process_, nullptr, size,
                                  MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    }
    ~RemoteAllocation() {
        if (address_) VirtualFreeEx(process_, address_, 0, MEM_RELEASE);
    }
    RemoteAllocation(const RemoteAllocation&) = delete;
    RemoteAllocation& operator=(const RemoteAllocation&) = delete;
    void* get() const noexcept { return address_; }

private:
    HANDLE process_ = nullptr;
    void* address_ = nullptr;
};

std::wstring windows_error(const wchar_t* context) {
    const DWORD code = GetLastError();
    wchar_t* message = nullptr;
    DWORD length = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, 0, reinterpret_cast<LPWSTR>(&message), 0, nullptr);
    std::wstring result = context;
    result += L" (" + std::to_wstring(code) + L")";
    if (length && message) {
        while (length > 0 &&
               (message[length - 1] == L'\r' || message[length - 1] == L'\n')) {
            --length;
        }
        result += L": ";
        result.append(message, length);
    }
    if (message) LocalFree(message);
    return result;
}

std::wstring strip_extended_prefix(const std::wstring& path) {
    if (path.rfind(L"\\\\?\\UNC\\", 0) == 0) {
        return L"\\\\" + path.substr(8);
    }
    if (path.rfind(L"\\\\?\\", 0) == 0) return path.substr(4);
    return path;
}

bool resolve_existing_file(const std::wstring& input, std::wstring* resolved,
                           std::wstring* error) {
    HANDLE file = CreateFileW(input.c_str(), FILE_READ_ATTRIBUTES,
                              FILE_SHARE_READ | FILE_SHARE_WRITE |
                                  FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        if (error) *error = windows_error(L"找不到或無法開啟指定檔案");
        return false;
    }
    UniqueHandle guard(file);

    BY_HANDLE_FILE_INFORMATION information{};
    if (!GetFileInformationByHandle(file, &information) ||
        (information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        if (error) *error = L"指定路徑不是一般檔案。";
        return false;
    }

    const DWORD required = GetFinalPathNameByHandleW(
        file, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (required == 0) {
        if (error) *error = windows_error(L"無法解析檔案的最終路徑");
        return false;
    }
    std::vector<wchar_t> buffer(static_cast<std::size_t>(required) + 1);
    const DWORD written = GetFinalPathNameByHandleW(
        file, buffer.data(), static_cast<DWORD>(buffer.size()),
        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (written == 0 || written >= buffer.size()) {
        if (error) *error = windows_error(L"無法解析檔案的最終路徑");
        return false;
    }
    *resolved = strip_extended_prefix(std::wstring(buffer.data(), written));
    if (resolved->size() >= MAX_PATH) {
        if (error) *error = L"目前版本不支援超過 MAX_PATH 的檔案路徑。";
        return false;
    }
    return true;
}

bool is_unc_path(const std::wstring& path) noexcept {
    return path.size() >= 2 && path[0] == L'\\' && path[1] == L'\\';
}

bool has_exe_extension(const std::wstring& path) {
    const auto slash = path.find_last_of(L"\\/");
    const auto dot = path.find_last_of(L'.');
    if (dot == std::wstring::npos ||
        (slash != std::wstring::npos && dot < slash)) {
        return false;
    }
    return _wcsicmp(path.c_str() + dot, L".exe") == 0;
}

bool path_is_within(const std::wstring& path,
                    const std::wstring& directory) {
    std::wstring prefix = directory;
    while (!prefix.empty() &&
           (prefix.back() == L'\\' || prefix.back() == L'/')) {
        prefix.pop_back();
    }
    if (path.size() <= prefix.size() ||
        _wcsnicmp(path.c_str(), prefix.c_str(), prefix.size()) != 0) {
        return false;
    }
    return path[prefix.size()] == L'\\' || path[prefix.size()] == L'/';
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
        buffer.resize(buffer.size() * 2);
    }
}

std::wstring parent_directory(const std::wstring& path) {
    const auto slash = path.find_last_of(L"\\/");
    return slash == std::wstring::npos ? std::wstring{} : path.substr(0, slash);
}

std::wstring file_name(const std::wstring& path) {
    const auto slash = path.find_last_of(L"\\/");
    return slash == std::wstring::npos ? path : path.substr(slash + 1);
}

std::wstring quote_argument(const std::wstring& argument) {
    if (argument.empty()) return L"\"\"";
    if (argument.find_first_of(L" \t\"") == std::wstring::npos) {
        return argument;
    }

    std::wstring quoted = L"\"";
    std::size_t backslashes = 0;
    for (const wchar_t character : argument) {
        if (character == L'\\') {
            ++backslashes;
        } else if (character == L'\"') {
            quoted.append(backslashes * 2 + 1, L'\\');
            quoted.push_back(L'\"');
            backslashes = 0;
        } else {
            quoted.append(backslashes, L'\\');
            backslashes = 0;
            quoted.push_back(character);
        }
    }
    quoted.append(backslashes * 2, L'\\');
    quoted.push_back(L'\"');
    return quoted;
}

std::wstring build_command_line(
    const ffb::launcher::LaunchRequest& request) {
    std::wstring command = quote_argument(request.game_path);
    for (const auto& argument : request.game_arguments) {
        command.push_back(L' ');
        command += quote_argument(argument);
    }
    return command;
}

bool same_path(const std::wstring& left, const std::wstring& right) noexcept {
    return _wcsicmp(left.c_str(), right.c_str()) == 0;
}

struct DebugModule {
    std::wstring name;
    std::wstring path;
    std::uintptr_t base = 0;
};

struct DebugSession {
    PROCESS_INFORMATION process{};
    std::vector<DebugModule> modules;
    std::uintptr_t image_base = 0;
};

std::wstring path_from_debug_file(HANDLE file) {
    if (!file || file == INVALID_HANDLE_VALUE) return {};
    const DWORD required = GetFinalPathNameByHandleW(
        file, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (required == 0) return {};
    std::vector<wchar_t> buffer(static_cast<std::size_t>(required) + 1);
    const DWORD written = GetFinalPathNameByHandleW(
        file, buffer.data(), static_cast<DWORD>(buffer.size()),
        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (written == 0 || written >= buffer.size()) return {};
    return strip_extended_prefix(std::wstring(buffer.data(), written));
}

void record_debug_module(DebugSession* session, void* module_base,
                         HANDLE file) {
    if (!session || !module_base) return;
    const std::wstring path = path_from_debug_file(file);
    if (path.empty()) return;
    const auto base = reinterpret_cast<std::uintptr_t>(module_base);
    for (auto& module : session->modules) {
        if (module.base == base) {
            module.path = path;
            module.name = file_name(path);
            return;
        }
    }
    if (session->modules.size() >= 4096) return;
    session->modules.push_back(DebugModule{file_name(path), path, base});
}

void observe_debug_event(const DEBUG_EVENT& event, DebugSession* session,
                         HANDLE protected_thread = nullptr) {
    if (event.dwDebugEventCode == CREATE_PROCESS_DEBUG_EVENT) {
        const auto& information = event.u.CreateProcessInfo;
        session->image_base =
            reinterpret_cast<std::uintptr_t>(information.lpBaseOfImage);
        record_debug_module(session, information.lpBaseOfImage,
                            information.hFile);
        if (information.hFile) CloseHandle(information.hFile);
        if (information.hProcess &&
            information.hProcess != session->process.hProcess) {
            CloseHandle(information.hProcess);
        }
        if (information.hThread &&
            information.hThread != session->process.hThread &&
            information.hThread != protected_thread) {
            CloseHandle(information.hThread);
        }
    } else if (event.dwDebugEventCode == CREATE_THREAD_DEBUG_EVENT) {
        const HANDLE thread = event.u.CreateThread.hThread;
        if (thread && thread != session->process.hThread &&
            thread != protected_thread) {
            CloseHandle(thread);
        }
    } else if (event.dwDebugEventCode == LOAD_DLL_DEBUG_EVENT) {
        record_debug_module(session, event.u.LoadDll.lpBaseOfDll,
                            event.u.LoadDll.hFile);
        if (event.u.LoadDll.hFile) CloseHandle(event.u.LoadDll.hFile);
    } else if (event.dwDebugEventCode == UNLOAD_DLL_DEBUG_EVENT) {
        const auto base = reinterpret_cast<std::uintptr_t>(
            event.u.UnloadDll.lpBaseOfDll);
        session->modules.erase(
            std::remove_if(session->modules.begin(), session->modules.end(),
                           [base](const DebugModule& module) {
                               return module.base == base;
                           }),
            session->modules.end());
    }
}

bool find_debug_module(const DebugSession& session,
                       const std::wstring& expected_name,
                       const std::wstring* expected_path,
                       std::uintptr_t* base, std::wstring* error) {
    bool conflicting_name_found = false;
    std::wstring observed_modules;
    for (const auto& module : session.modules) {
        if (observed_modules.size() < 240) {
            if (!observed_modules.empty()) observed_modules += L", ";
            observed_modules += module.name;
        }
        if (_wcsicmp(module.name.c_str(), expected_name.c_str()) != 0) {
            continue;
        }
        if (!expected_path || same_path(module.path, *expected_path)) {
            *base = module.base;
            return true;
        }
        conflicting_name_found = true;
    }
    if (error) {
        *error = conflicting_name_found
                     ? L"同名 Hook DLL 已從另一個路徑載入，已中止以避免誤用。"
                     : L"在新程序中找不到預期的模組：" + expected_name +
                           (observed_modules.empty()
                                ? L""
                                : L"（目前可見：" + observed_modules + L"）");
    }
    return false;
}

bool remote_function_address(const DebugSession& session,
                             FARPROC local_function,
                             std::uintptr_t* remote_address,
                             std::wstring* error) {
    HMODULE owner = nullptr;
    if (!GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(local_function), &owner)) {
        if (error) *error = windows_error(L"無法定位 Windows 載入函式所屬模組");
        return false;
    }
    wchar_t module_path[MAX_PATH]{};
    if (!GetModuleFileNameW(owner, module_path, MAX_PATH)) {
        if (error) *error = windows_error(L"無法讀取 Windows 系統模組路徑");
        return false;
    }
    const auto local_base = reinterpret_cast<std::uintptr_t>(owner);
    const auto function = reinterpret_cast<std::uintptr_t>(local_function);
    if (function < local_base) {
        if (error) *error = L"Windows 載入函式位址無效。";
        return false;
    }
    std::uintptr_t remote_base = 0;
    if (!find_debug_module(session, file_name(module_path), nullptr,
                           &remote_base, error)) {
        return false;
    }
    *remote_address = remote_base + (function - local_base);
    return true;
}

bool run_remote_thread(DebugSession* session, std::uintptr_t start_address,
                       void* parameter, DWORD* exit_code,
                       std::wstring* error) {
    DWORD remote_thread_id = 0;
    UniqueHandle thread(CreateRemoteThread(
        session->process.hProcess, nullptr, 0,
        reinterpret_cast<LPTHREAD_START_ROUTINE>(start_address), parameter, 0,
        &remote_thread_id));
    if (!thread) {
        if (error) *error = windows_error(L"無法在剛建立的程序中初始化 Hook");
        return false;
    }
    const ULONGLONG deadline = GetTickCount64() + kRemoteCallTimeoutMs;
    std::wstring observed_events;
    for (;;) {
        const DWORD thread_wait = WaitForSingleObject(thread.get(), 0);
        if (thread_wait == WAIT_FAILED) {
            if (error) *error = windows_error(L"無法檢查 Hook 初始化執行緒");
            return false;
        }
        if (thread_wait == WAIT_OBJECT_0) {
            DWORD result = 0;
            if (!GetExitCodeThread(thread.get(), &result)) {
                if (error) *error = windows_error(L"無法取得 Hook 初始化結果");
                return false;
            }
            if (exit_code) *exit_code = result;
            return true;
        }

        const ULONGLONG now = GetTickCount64();
        if (now >= deadline) {
            if (error) *error = L"Hook 初始化逾時，遊戲尚未啟動。";
            return false;
        }
        DEBUG_EVENT event{};
        if (!WaitForDebugEvent(&event,
                               static_cast<DWORD>(deadline - now))) {
            if (error) {
                *error = windows_error(L"無法等待 Hook 初始化事件") +
                         (observed_events.empty()
                              ? L""
                              : L"（已處理事件：" + observed_events + L"）");
            }
            return false;
        }
        if (observed_events.size() < 512) {
            if (!observed_events.empty()) observed_events += L", ";
            observed_events += std::to_wstring(event.dwDebugEventCode);
            if (event.dwDebugEventCode == EXCEPTION_DEBUG_EVENT) {
                observed_events +=
                    L"/" + std::to_wstring(
                                event.u.Exception.ExceptionRecord.ExceptionCode);
            }
        }
        observe_debug_event(event, session, thread.get());

        const bool process_exited =
            event.dwDebugEventCode == EXIT_PROCESS_DEBUG_EVENT;
        const bool remote_thread_exited =
            event.dwDebugEventCode == EXIT_THREAD_DEBUG_EVENT &&
            event.dwThreadId == remote_thread_id;
        const DWORD remote_thread_exit_code =
            remote_thread_exited ? event.u.ExitThread.dwExitCode : 0;
        const DWORD continue_status =
            event.dwDebugEventCode == EXCEPTION_DEBUG_EVENT
                ? DBG_EXCEPTION_NOT_HANDLED
                : DBG_CONTINUE;
        if (!ContinueDebugEvent(event.dwProcessId, event.dwThreadId,
                                continue_status)) {
            if (error) *error = windows_error(L"無法繼續 Hook 初始化事件");
            return false;
        }
        if (process_exited) {
            if (error) *error = L"遊戲在 Hook 初始化期間結束。";
            return false;
        }
        if (remote_thread_exited) {
            if (exit_code) *exit_code = remote_thread_exit_code;
            return true;
        }
    }
}

struct EntryBreakpoint {
    BYTE original_byte = 0;
    bool armed = false;
};

bool read_remote_entry_point(const DebugSession& session,
                             std::uintptr_t* entry_point,
                             std::wstring* error) {
    if (session.image_base == 0) {
        if (error) *error = L"初始事件缺少遊戲映像基底。";
        return false;
    }

    IMAGE_DOS_HEADER dos{};
    SIZE_T read = 0;
    if (!ReadProcessMemory(session.process.hProcess,
                           reinterpret_cast<const void*>(session.image_base),
                           &dos, sizeof(dos), &read) ||
        read != sizeof(dos) || dos.e_magic != IMAGE_DOS_SIGNATURE ||
        dos.e_lfanew <= 0 || dos.e_lfanew > 1024 * 1024) {
        if (error) *error = windows_error(L"無法讀取遊戲 PE 標頭");
        return false;
    }

    IMAGE_NT_HEADERS nt{};
    const auto pe_offset = static_cast<std::uintptr_t>(dos.e_lfanew);
    if (session.image_base >
        (std::numeric_limits<std::uintptr_t>::max)() - pe_offset) {
        if (error) *error = L"遊戲 PE 標頭位址溢位。";
        return false;
    }
    const auto nt_address = session.image_base + pe_offset;
    if (!ReadProcessMemory(session.process.hProcess,
                           reinterpret_cast<const void*>(nt_address), &nt,
                           sizeof(nt), &read) ||
        read != sizeof(nt) || nt.Signature != IMAGE_NT_SIGNATURE ||
        nt.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR_MAGIC ||
        nt.OptionalHeader.AddressOfEntryPoint == 0 ||
        nt.OptionalHeader.AddressOfEntryPoint >=
            nt.OptionalHeader.SizeOfImage) {
        if (error) *error = L"遊戲 PE 入口點無效。";
        return false;
    }
    const auto entry_rva =
        static_cast<std::uintptr_t>(nt.OptionalHeader.AddressOfEntryPoint);
    if (session.image_base >
        (std::numeric_limits<std::uintptr_t>::max)() - entry_rva) {
        if (error) *error = L"遊戲 PE 入口點位址溢位。";
        return false;
    }
    *entry_point = session.image_base + entry_rva;
    return true;
}

bool write_remote_code_byte(HANDLE process, std::uintptr_t address, BYTE value,
                            std::wstring* error) {
    void* destination = reinterpret_cast<void*>(address);
    DWORD old_protection = 0;
    if (!VirtualProtectEx(process, destination, sizeof(value),
                          PAGE_EXECUTE_READWRITE, &old_protection)) {
        if (error) *error = windows_error(L"無法開啟遊戲入口同步點");
        return false;
    }

    SIZE_T written = 0;
    const bool write_ok =
        WriteProcessMemory(process, destination, &value, sizeof(value),
                           &written) &&
        written == sizeof(value);
    const bool flush_ok =
        FlushInstructionCache(process, destination, sizeof(value)) != FALSE;
    DWORD ignored = 0;
    const bool protection_ok =
        VirtualProtectEx(process, destination, sizeof(value), old_protection,
                         &ignored) != FALSE;
    if (!write_ok || !flush_ok || !protection_ok) {
        if (error) *error = windows_error(L"無法寫入遊戲入口同步點");
        return false;
    }
    return true;
}

bool arm_entry_breakpoint(const DebugSession& session,
                          std::uintptr_t entry_point,
                          EntryBreakpoint* breakpoint,
                          std::wstring* error) {
    SIZE_T read = 0;
    if (!ReadProcessMemory(session.process.hProcess,
                           reinterpret_cast<const void*>(entry_point),
                           &breakpoint->original_byte,
                           sizeof(breakpoint->original_byte), &read) ||
        read != sizeof(breakpoint->original_byte)) {
        if (error) *error = windows_error(L"無法讀取遊戲入口同步點");
        return false;
    }
    if (!write_remote_code_byte(session.process.hProcess, entry_point, 0xCC,
                                error)) {
        return false;
    }
    breakpoint->armed = true;
    return true;
}

bool restore_entry_breakpoint(const DebugSession& session,
                              std::uintptr_t entry_point,
                              const EntryBreakpoint& breakpoint,
                              std::wstring* error) {
    if (!breakpoint.armed) return true;
    return write_remote_code_byte(session.process.hProcess, entry_point,
                                  breakpoint.original_byte, error);
}

bool rewind_thread_to_entry_and_single_step(HANDLE thread,
                                            std::uintptr_t entry_point,
                                            std::wstring* error) {
    CONTEXT context{};
    context.ContextFlags = CONTEXT_CONTROL;
    if (!GetThreadContext(thread, &context)) {
        if (error) *error = windows_error(L"無法讀取遊戲入口執行位置");
        return false;
    }
#if defined(_WIN64)
    context.Rip = static_cast<DWORD64>(entry_point);
#else
    context.Eip = static_cast<DWORD>(entry_point);
#endif
    context.EFlags |= 0x100;
    if (!SetThreadContext(thread, &context)) {
        if (error) *error = windows_error(L"無法還原遊戲入口執行位置");
        return false;
    }
    return true;
}

bool clear_single_step(HANDLE thread, std::wstring* error) {
    CONTEXT context{};
    context.ContextFlags = CONTEXT_CONTROL;
    if (!GetThreadContext(thread, &context)) {
        if (error) *error = windows_error(L"無法讀取入口單步狀態");
        return false;
    }
    context.EFlags &= ~static_cast<DWORD>(0x100);
    if (!SetThreadContext(thread, &context)) {
        if (error) *error = windows_error(L"無法清除入口單步狀態");
        return false;
    }
    return true;
}

bool pause_after_loader_initialization(const PROCESS_INFORMATION& process,
                                       DebugSession* session,
                                       std::wstring* error) {
    session->process = process;
    bool initial_breakpoint_seen = false;
    bool entry_single_step_pending = false;
    std::uintptr_t entry_point = 0;
    EntryBreakpoint entry_breakpoint;
    const ULONGLONG deadline = GetTickCount64() + kStartupTimeoutMs;
    for (;;) {
        const ULONGLONG now = GetTickCount64();
        if (now >= deadline) {
            if (error) *error = L"等待遊戲完成 Windows 載入器初始化時逾時。";
            return false;
        }

        DEBUG_EVENT event{};
        if (!WaitForDebugEvent(&event,
                               static_cast<DWORD>(deadline - now))) {
            if (error) *error = windows_error(L"無法等待遊戲的初始載入事件");
            return false;
        }
        observe_debug_event(event, session);

        if (event.dwDebugEventCode == EXIT_PROCESS_DEBUG_EVENT) {
            ContinueDebugEvent(event.dwProcessId, event.dwThreadId,
                               DBG_CONTINUE);
            if (error) *error = L"遊戲在 Windows 載入器初始化期間結束。";
            return false;
        }

        if (event.dwDebugEventCode == EXCEPTION_DEBUG_EVENT &&
            !initial_breakpoint_seen &&
            event.u.Exception.ExceptionRecord.ExceptionCode ==
                EXCEPTION_BREAKPOINT) {
            if (!read_remote_entry_point(*session, &entry_point, error) ||
                !arm_entry_breakpoint(*session, entry_point,
                                      &entry_breakpoint, error)) {
                ContinueDebugEvent(event.dwProcessId, event.dwThreadId,
                                   DBG_CONTINUE);
                return false;
            }
            initial_breakpoint_seen = true;
            if (!ContinueDebugEvent(event.dwProcessId, event.dwThreadId,
                                    DBG_CONTINUE)) {
                if (error) *error = windows_error(L"無法開始遊戲入口同步");
                return false;
            }
            continue;
        }

        if (event.dwDebugEventCode == EXCEPTION_DEBUG_EVENT &&
            initial_breakpoint_seen &&
            event.u.Exception.ExceptionRecord.ExceptionCode ==
                EXCEPTION_BREAKPOINT &&
            reinterpret_cast<std::uintptr_t>(
                event.u.Exception.ExceptionRecord.ExceptionAddress) ==
                entry_point &&
            event.dwThreadId == process.dwThreadId) {
            if (!restore_entry_breakpoint(*session, entry_point,
                                          entry_breakpoint, error) ||
                !rewind_thread_to_entry_and_single_step(
                    process.hThread, entry_point, error)) {
                ContinueDebugEvent(event.dwProcessId, event.dwThreadId,
                                   DBG_CONTINUE);
                return false;
            }
            entry_single_step_pending = true;
            if (!ContinueDebugEvent(event.dwProcessId, event.dwThreadId,
                                    DBG_CONTINUE)) {
                if (error) *error = windows_error(L"無法開始遊戲入口單步同步");
                return false;
            }
            continue;
        }

        if (event.dwDebugEventCode == EXCEPTION_DEBUG_EVENT &&
            entry_single_step_pending &&
            event.u.Exception.ExceptionRecord.ExceptionCode ==
                EXCEPTION_SINGLE_STEP &&
            event.dwThreadId == process.dwThreadId) {
            if (!clear_single_step(process.hThread, error)) {
                ContinueDebugEvent(event.dwProcessId, event.dwThreadId,
                                   DBG_CONTINUE);
                return false;
            }
            if (SuspendThread(process.hThread) == static_cast<DWORD>(-1)) {
                ContinueDebugEvent(event.dwProcessId, event.dwThreadId,
                                   DBG_CONTINUE);
                if (error) *error = windows_error(L"無法暫停遊戲主執行緒");
                return false;
            }
            if (!ContinueDebugEvent(event.dwProcessId, event.dwThreadId,
                                    DBG_CONTINUE)) {
                if (error) *error = windows_error(L"無法完成初始載入事件");
                return false;
            }
            return true;
        }

        const DWORD continue_status =
            event.dwDebugEventCode == EXCEPTION_DEBUG_EVENT
                ? DBG_EXCEPTION_NOT_HANDLED
                : DBG_CONTINUE;
        if (!ContinueDebugEvent(event.dwProcessId, event.dwThreadId,
                                continue_status)) {
            if (error) *error = windows_error(L"無法繼續遊戲的初始載入事件");
            return false;
        }
    }
}

FARPROC find_hook_initializer(HMODULE local_hook) noexcept {
    FARPROC initializer = GetProcAddress(local_hook, "FFBHookInitialize");
#if !defined(_WIN64)
    if (!initializer) {
        initializer = GetProcAddress(local_hook, "_FFBHookInitialize@4");
    }
#endif
    return initializer;
}

}  // namespace

namespace ffb::launcher {

bool launch_offline_game(const LaunchRequest& request, DWORD* process_id,
                         std::wstring* error) {
    std::wstring game_path;
    if (!resolve_existing_file(request.game_path, &game_path, error)) {
        return false;
    }
    if (is_unc_path(game_path)) {
        if (error) *error = L"安全限制：不能從網路分享路徑啟動遊戲。";
        return false;
    }
    if (!has_exe_extension(game_path)) {
        if (error) *error = L"請選擇副檔名為 .exe 的遊戲執行檔。";
        return false;
    }

    wchar_t windows_directory[MAX_PATH]{};
    if (GetWindowsDirectoryW(windows_directory, MAX_PATH) == 0) {
        if (error) *error = windows_error(L"無法確認 Windows 系統目錄");
        return false;
    }
    if (path_is_within(game_path, windows_directory)) {
        if (error) *error = L"安全限制：不能以 Windows 系統目錄內的程式作為目標。";
        return false;
    }

    const std::wstring own_path = executable_path();
    if (own_path.empty()) {
        if (error) *error = windows_error(L"無法定位啟動器本身");
        return false;
    }
    std::wstring hook_path;
    const std::wstring hook_candidate =
        parent_directory(own_path) + L"\\" + kHookFileName;
    if (!resolve_existing_file(hook_candidate, &hook_path, error)) {
        if (error) *error = L"啟動器旁缺少固定的 FFBInterceptor.Hook.dll。";
        return false;
    }
    if (is_unc_path(hook_path)) {
        if (error) *error = L"安全限制：啟動器與 Hook DLL 必須位於本機磁碟。";
        return false;
    }

    std::wstring architecture_error;
    const auto game_architecture =
        read_pe_architecture(game_path, &architecture_error);
    const auto hook_architecture =
        read_pe_architecture(hook_path, &architecture_error);
    const auto launcher_architecture = current_architecture();
    if (game_architecture == PeArchitecture::unknown ||
        hook_architecture == PeArchitecture::unknown) {
        if (error) *error = architecture_error;
        return false;
    }
    if (game_architecture != launcher_architecture ||
        hook_architecture != launcher_architecture) {
        if (error) {
            *error = L"架構不相容：遊戲是 " +
                     std::wstring(architecture_name(game_architecture)) +
                     L"，目前啟動器是 " +
                     architecture_name(launcher_architecture) + L"。";
        }
        return false;
    }

    LaunchRequest normalized_request = request;
    normalized_request.game_path = game_path;
    std::wstring command_line = build_command_line(normalized_request);
    std::vector<wchar_t> mutable_command(command_line.begin(),
                                         command_line.end());
    mutable_command.push_back(L'\0');

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION information{};
    const std::wstring working_directory = parent_directory(game_path);
    if (!CreateProcessW(
            game_path.c_str(), mutable_command.data(), nullptr, nullptr, FALSE,
            DEBUG_ONLY_THIS_PROCESS | CREATE_UNICODE_ENVIRONMENT, nullptr,
            working_directory.c_str(), &startup, &information)) {
        if (error) *error = windows_error(L"無法建立遊戲程序");
        return false;
    }
    SuspendedChild child(information);

    DebugSession debug_session;
    if (!pause_after_loader_initialization(information, &debug_session, error)) {
        return false;
    }

    const SIZE_T hook_path_bytes = (hook_path.size() + 1) * sizeof(wchar_t);
    RemoteAllocation remote_path(child.process(), hook_path_bytes);
    if (!remote_path.get()) {
        if (error) *error = windows_error(L"無法配置 Hook 初始化記憶體");
        return false;
    }
    SIZE_T written = 0;
    if (!WriteProcessMemory(child.process(), remote_path.get(),
                            hook_path.c_str(), hook_path_bytes, &written) ||
        written != hook_path_bytes) {
        if (error) *error = windows_error(L"無法傳遞固定 Hook DLL 路徑");
        return false;
    }

    HMODULE kernel32 = GetModuleHandleW(L"kernel32.dll");
    FARPROC load_library =
        kernel32 ? GetProcAddress(kernel32, "LoadLibraryW") : nullptr;
    std::uintptr_t remote_load_library = 0;
    if (!load_library ||
        !remote_function_address(debug_session, load_library,
                                 &remote_load_library, error)) {
        if (error && error->empty()) {
            *error = L"無法解析 Windows 的 LoadLibraryW。";
        }
        return false;
    }

    if (!run_remote_thread(&debug_session, remote_load_library,
                           remote_path.get(), nullptr, error)) {
        return false;
    }

    std::uintptr_t remote_hook_base = 0;
    if (!find_debug_module(debug_session, kHookFileName, &hook_path,
                           &remote_hook_base, error)) {
        return false;
    }

    HMODULE local_hook = LoadLibraryExW(
        hook_path.c_str(), nullptr, DONT_RESOLVE_DLL_REFERENCES);
    if (!local_hook) {
        if (error) *error = windows_error(L"無法驗證 Hook DLL 匯出函式");
        return false;
    }
    const FARPROC initializer = find_hook_initializer(local_hook);
    const auto local_base = reinterpret_cast<std::uintptr_t>(local_hook);
    const auto local_initializer =
        reinterpret_cast<std::uintptr_t>(initializer);
    if (!initializer || local_initializer < local_base) {
        FreeLibrary(local_hook);
        if (error) *error = L"Hook DLL 缺少 FFBHookInitialize 匯出函式。";
        return false;
    }
    const std::uintptr_t initializer_rva = local_initializer - local_base;
    FreeLibrary(local_hook);

    DWORD initialization_result = 0;
    if (!run_remote_thread(&debug_session,
                           remote_hook_base + initializer_rva, nullptr,
                           &initialization_result, error)) {
        return false;
    }
    if (initialization_result != 1) {
        if (error) {
            *error = L"Hook DLL 初始化失敗（狀態 " +
                     std::to_wstring(initialization_result) +
                     L"），遊戲尚未啟動。";
        }
        return false;
    }

    if (!DebugSetProcessKillOnExit(FALSE)) {
        if (error) *error = windows_error(L"無法設定安全的除錯解除行為");
        return false;
    }
    if (ResumeThread(child.thread()) == static_cast<DWORD>(-1)) {
        if (error) *error = windows_error(L"無法恢復遊戲主執行緒");
        return false;
    }
    if (process_id) *process_id = child.process_id();
    child.release();
    return true;
}

}  // namespace ffb::launcher
