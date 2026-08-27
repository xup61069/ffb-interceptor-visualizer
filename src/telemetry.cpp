// SPDX-License-Identifier: GPL-3.0-only
#include "telemetry.h"

#include <algorithm>
#include <cstddef>
#include <cstdio>
#include <cstring>

namespace ffb {
namespace {

constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\ffb-interceptor-v1";

Telemetry::Node* node_from_entry(PSLIST_ENTRY entry) {
    return CONTAINING_RECORD(entry, Telemetry::Node, entry);
}

std::size_t utf8_basename(char* out, std::size_t capacity) {
    wchar_t path[MAX_PATH]{};
    const DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
    const wchar_t* base = path;
    for (DWORD i = 0; i < length; ++i) {
        if (path[i] == L'\\' || path[i] == L'/') base = path + i + 1;
    }
    if (capacity == 0) return 0;
    const int converted = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                               base, -1, out,
                                               static_cast<int>(capacity), nullptr, nullptr);
    if (converted <= 0) out[0] = '\0';
    return converted > 0 ? static_cast<std::size_t>(converted - 1) : 0;
}

}  // namespace

Telemetry& Telemetry::instance() {
    static Telemetry telemetry;
    return telemetry;
}

Telemetry::Telemetry() {
    InitializeSListHead(&m_free);
    InitializeSListHead(&m_pending);
    for (auto& node : m_nodes) InterlockedPushEntrySList(&m_free, &node.entry);
}

void Telemetry::start() {
    if (m_running.load(std::memory_order_acquire)) return;
    if (m_starting.test_and_set(std::memory_order_acquire)) return;

    // Keep the module mapped while the sender thread is alive. This avoids a
    // use-after-unload if a host calls FreeLibrary on its proxy explicitly.
    HMODULE self = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                GET_MODULE_HANDLE_EX_FLAG_PIN,
                            reinterpret_cast<LPCWSTR>(&Telemetry::instance), &self)) {
        m_starting.clear(std::memory_order_release);
        return;
    }

    m_wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!m_wake) {
        m_starting.clear(std::memory_order_release);
        return;
    }
    m_thread = CreateThread(nullptr, 0, &Telemetry::thread_entry, this, 0, nullptr);
    if (!m_thread) {
        CloseHandle(m_wake);
        m_wake = nullptr;
        m_starting.clear(std::memory_order_release);
        return;
    }
    m_running.store(true, std::memory_order_release);
    m_starting.clear(std::memory_order_release);
}

void Telemetry::emit(Event event) noexcept {
    if (!m_running.load(std::memory_order_acquire)) return;
    event.sequence = static_cast<std::uint64_t>(InterlockedIncrement64(&m_sequence));
    event.qpc_ticks = event.qpc_ticks == 0 ? qpc_now() : event.qpc_ticks;
    Node* node = node_from_entry(InterlockedPopEntrySList(&m_free));
    if (!node) {
        InterlockedIncrement64(&m_dropped);
        return;
    }
    node->event = event;
    InterlockedPushEntrySList(&m_pending, &node->entry);
    SetEvent(m_wake);
}

std::uint32_t Telemetry::next_device_id() noexcept {
    return static_cast<std::uint32_t>(InterlockedIncrement(&m_next_device));
}

std::uint32_t Telemetry::next_effect_id() noexcept {
    return static_cast<std::uint32_t>(InterlockedIncrement(&m_next_effect));
}

DWORD WINAPI Telemetry::thread_entry(void* context) {
    static_cast<Telemetry*>(context)->run();
    ExitThread(0);
}

HANDLE Telemetry::connect_pipe() noexcept {
    if (!WaitNamedPipeW(kPipeName, 250)) return INVALID_HANDLE_VALUE;
    return CreateFileW(kPipeName, GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                       FILE_ATTRIBUTE_NORMAL, nullptr);
}

Event Telemetry::hello_event() const noexcept {
    Event event{};
    event.type = MessageType::Hello;
    event.process_id = GetCurrentProcessId();
    event.qpc_frequency = qpc_frequency();
    std::snprintf(event.build_version, sizeof(event.build_version), "0.1.0");
    std::snprintf(event.session_id, sizeof(event.session_id), "%lu-%llu",
                  static_cast<unsigned long>(event.process_id),
                  static_cast<unsigned long long>(qpc_now()));
#if defined(_WIN64)
    event.flags = 64;
#else
    event.flags = 32;
#endif
    utf8_basename(event.text, sizeof(event.text));
    return event;
}

bool Telemetry::send_frame(HANDLE pipe, const Event& event) noexcept {
    const std::vector<std::uint8_t> frame = serialize_event(event);
    if (frame.size() > kMaxFrameSize) return false;
    std::size_t offset = 0;
    while (offset < frame.size()) {
        DWORD written = 0;
        if (!WriteFile(pipe, frame.data() + offset,
                       static_cast<DWORD>(frame.size() - offset), &written, nullptr) ||
            written == 0) {
            return false;
        }
        offset += written;
    }
    return true;
}

void Telemetry::recycle_or_drop_pending(bool count_as_drop) noexcept {
    PSLIST_ENTRY list = InterlockedFlushSList(&m_pending);
    while (list) {
        PSLIST_ENTRY next = list->Next;
        if (count_as_drop) InterlockedIncrement64(&m_dropped);
        InterlockedPushEntrySList(&m_free, list);
        list = next;
    }
}

void Telemetry::run() noexcept {
    volatile bool keep_running = true;
    while (keep_running) {
        HANDLE pipe = connect_pipe();
        if (pipe == INVALID_HANDLE_VALUE) {
            recycle_or_drop_pending(true);
            WaitForSingleObject(m_wake, 250);
            continue;
        }

        Event hello = hello_event();
        if (!send_frame(pipe, hello)) {
            CloseHandle(pipe);
            recycle_or_drop_pending(true);
            continue;
        }

        std::uint64_t reported_drops = 0;
        bool connected = true;
        while (connected) {
            PSLIST_ENTRY list = InterlockedFlushSList(&m_pending);
            std::array<Node*, kQueueCapacity> batch{};
            std::size_t count = 0;
            while (list && count < batch.size()) {
                PSLIST_ENTRY next = list->Next;
                batch[count++] = node_from_entry(list);
                list = next;
            }
            if (list) {
                while (list) {
                    PSLIST_ENTRY next = list->Next;
                    InterlockedIncrement64(&m_dropped);
                    InterlockedPushEntrySList(&m_free, list);
                    list = next;
                }
            }
            std::sort(batch.begin(), batch.begin() + count,
                      [](const Node* left, const Node* right) {
                          return left->event.sequence < right->event.sequence;
                      });
            for (std::size_t i = 0; i < count && connected; ++i) {
                connected = send_frame(pipe, batch[i]->event);
                InterlockedPushEntrySList(&m_free, &batch[i]->entry);
            }

            const auto drops = static_cast<std::uint64_t>(InterlockedCompareExchange64(&m_dropped, 0, 0));
            if (connected && drops != reported_drops) {
                Event notice{};
                notice.type = MessageType::DropNotice;
                notice.process_id = GetCurrentProcessId();
                notice.dropped = static_cast<std::uint32_t>(std::min<std::uint64_t>(drops, UINT32_MAX));
                notice.qpc_ticks = qpc_now();
                notice.sequence = static_cast<std::uint64_t>(InterlockedIncrement64(&m_sequence));
                connected = send_frame(pipe, notice);
                reported_drops = drops;
            }
            if (count == 0 && connected) WaitForSingleObject(m_wake, 50);
        }
        CloseHandle(pipe);
    }
}

}  // namespace ffb
