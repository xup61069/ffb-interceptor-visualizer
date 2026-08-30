// SPDX-License-Identifier: GPL-3.0-only
#include <windows.h>

#include <string>

#include "injector.h"
#include "pe_arch.h"

namespace {

void write_text(HANDLE destination, const std::wstring& message) {
    DWORD console_mode = 0;
    if (GetConsoleMode(destination, &console_mode)) {
        DWORD written = 0;
        WriteConsoleW(destination, message.data(),
                      static_cast<DWORD>(message.size()), &written, nullptr);
        return;
    }

    const int required = WideCharToMultiByte(
        CP_UTF8, 0, message.data(), static_cast<int>(message.size()), nullptr, 0,
        nullptr, nullptr);
    if (required <= 0) return;
    std::string utf8(static_cast<std::size_t>(required), '\0');
    WideCharToMultiByte(CP_UTF8, 0, message.data(),
                        static_cast<int>(message.size()), utf8.data(), required,
                        nullptr, nullptr);
    DWORD written = 0;
    WriteFile(destination, utf8.data(), static_cast<DWORD>(utf8.size()),
              &written, nullptr);
}

void write_output(const std::wstring& message) {
    write_text(GetStdHandle(STD_OUTPUT_HANDLE), message);
}

void write_error(const std::wstring& message) {
    write_text(GetStdHandle(STD_ERROR_HANDLE), message);
}

void print_usage() {
    write_output(
        L"FFB Interceptor 離線啟動器\n\n"
        L"用法：\n"
        L"  FFBInterceptor.Launcher.exe --offline-only --game "
        L"\"遊戲.exe\" -- [遊戲參數]\n\n"
        L"限制：只會建立新的遊戲程序、只載入同資料夾的固定 Hook DLL，"
        L"不支援連線／反作弊遊戲。\n");
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    bool offline_only = false;
    ffb::launcher::LaunchRequest request;

    for (int index = 1; index < argc; ++index) {
        const std::wstring argument = argv[index];
        if (argument == L"--help" || argument == L"-h") {
            print_usage();
            return 0;
        }
        if (argument == L"--offline-only") {
            offline_only = true;
            continue;
        }
        if (argument == L"--game") {
            if (++index >= argc) {
                write_error(L"錯誤：--game 後面缺少遊戲路徑。\n");
                return 2;
            }
            request.game_path = argv[index];
            continue;
        }
        if (argument == L"--") {
            for (++index; index < argc; ++index) {
                request.game_arguments.emplace_back(argv[index]);
            }
            break;
        }
        write_error(L"錯誤：不支援的參數：" + argument + L"\n");
        return 2;
    }

    if (!offline_only) {
        write_error(L"錯誤：這個啟動器只供離線／單機使用，必須加上 "
                    L"--offline-only。\n");
        return 2;
    }
    if (request.game_path.empty()) {
        print_usage();
        return 2;
    }

    std::wstring error;
    DWORD process_id = 0;
    if (!ffb::launcher::launch_offline_game(request, &process_id, &error)) {
        write_error(L"啟動失敗：" + error + L"\n");
        return 1;
    }

    write_output(
        L"已啟動離線遊戲（PID " + std::to_wstring(process_id) + L"，" +
        ffb::launcher::architecture_name(
            ffb::launcher::current_architecture()) +
        L"）；遊戲資料夾未被修改。\n");
    return 0;
}
