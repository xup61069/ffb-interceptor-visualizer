// SPDX-License-Identifier: GPL-3.0-only
#include "telemetry.h"

#include <algorithm>
#include <cstddef>
#include <cstdio>
#include <cstring>

namespace ffb {
namespace {

#ifndef FFB_BUILD_VERSION
#define FFB_BUILD_VERSION "0.0.0-dev"
#endif

constexpr wchar_t kViewerPipeName[] = L"\\\\.\\pipe\\ffb-interceptor-v1";
constexpr wchar_t kSimHubPipeName[] =
    L"\\\\.\\pipe\\ffb-interceptor-simhub-v1";

Telemetry::Node* node_from_entry(PSLIST_ENTRY entry) {
    return CONTAINING_RECORD(entry, Telemetry::Node, entry);
}

std::size_t utf8_basename(char* out, std::size_t capacity) {
    wchar_t path[MAX_PATH]{};
    DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
    // On older Windows versions a result equal to the buffer size means the
    // path may not be NUL-terminated.  Keep the conversion bounded even when
    // the executable path is longer than MAX_PATH.
    if (length >= MAX_PATH) {
        path[MAX_PATH - 1] = L'\0';
        length = MAX_PATH - 1;
    }
    const wchar_t* base = path;
    for (DWORD i = 0; i < length; ++i) {
        if (path[i] == L'\\' || path[i] == L'/') base = path + i + 1;
    }
    if (capacity == 0) return 0;
    const auto base_length = static_cast<int>(
        length - static_cast<DWORD>(base - path));
    // Convert the complete MAX_PATH basename first. WideCharToMultiByte does
    // not produce partial output when the caller's destination is too small.
    std::array<char, MAX_PATH * 4> utf8{};
    const int converted = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, base, base_length, utf8.data(),
        static_cast<int>(utf8.size()), nullptr, nullptr);
    if (converted <= 0) {
        out[0] = '\0';
        return 0;
    }
    return copy_utf8_truncated(out, capacity, utf8.data(),
                               static_cast<std::size_t>(converted));
}

}  // namespace

Telemetry& Telemetry::instance() {
    static Telemetry telemetry;
    return telemetry;
}

Telemetry::Telemetry() {
    // A producer session identifies this proxy instance, not an individual
    // pipe connection.  Keep it stable across both sinks and reconnects so a
    // manual PID/session selection remains valid.
    std::snprintf(m_session_id.data(), m_session_id.size(), "%lu-%llu",
                  static_cast<unsigned long>(GetCurrentProcessId()),
                  static_cast<unsigned long long>(qpc_now()));
    const std::array<const wchar_t*, kSinkCount> pipe_names{
        kViewerPipeName,
        kSimHubPipeName,
    };
    for (std::size_t index = 0; index < m_sinks.size(); ++index) {
        auto& sink = m_sinks[index];
        InitializeSListHead(&sink.free);
        InitializeSListHead(&sink.pending);
        for (auto& node : sink.nodes) {
            InterlockedPushEntrySList(&sink.free, &node.entry);
        }
        sink.pipe_name = pipe_names[index];
        sink.owner = this;
    }
}

void Telemetry::start() {
    const bool all_running = std::all_of(
        m_sinks.begin(), m_sinks.end(), [](const Sink& sink) {
            return sink.running.load(std::memory_order_acquire);
        });
    if (all_running) return;
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

    for (auto& sink : m_sinks) {
        if (sink.running.load(std::memory_order_acquire)) continue;

        sink.wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!sink.wake) continue;

        sink.thread =
            CreateThread(nullptr, 0, &Telemetry::thread_entry, &sink, 0, nullptr);
        if (!sink.thread) {
            CloseHandle(sink.wake);
            sink.wake = nullptr;
            continue;
        }
        sink.running.store(true, std::memory_order_release);
    }
    m_starting.clear(std::memory_order_release);
}

void Telemetry::emit(Event event) noexcept {
    const bool any_running = std::any_of(
        m_sinks.begin(), m_sinks.end(), [](const Sink& sink) {
            return sink.running.load(std::memory_order_acquire);
        });
    if (!any_running) return;

    AcquireSRWLockExclusive(&m_emit_lock);
    event.sequence =
        static_cast<std::uint64_t>(InterlockedIncrement64(&m_sequence));
    event.qpc_ticks = event.qpc_ticks == 0 ? qpc_now() : event.qpc_ticks;
    for (auto& sink : m_sinks) {
        if (sink.running.load(std::memory_order_acquire)) enqueue(sink, event);
    }
    ReleaseSRWLockExclusive(&m_emit_lock);
}

void Telemetry::enqueue(Sink& sink, const Event& event) noexcept {
    Node* node = node_from_entry(InterlockedPopEntrySList(&sink.free));
    if (!node) {
        InterlockedIncrement64(&sink.dropped);
        return;
    }
    node->event = event;
    InterlockedPushEntrySList(&sink.pending, &node->entry);
    SetEvent(sink.wake);
}

std::uint32_t Telemetry::next_device_id() noexcept {
    return static_cast<std::uint32_t>(InterlockedIncrement(&m_next_device));
}

std::uint32_t Telemetry::next_effect_id() noexcept {
    return static_cast<std::uint32_t>(InterlockedIncrement(&m_next_effect));
}

#if defined(FFB_TESTING)
bool Telemetry::begin_benchmark_for_test() noexcept {
    for (const auto& sink : m_sinks) {
        if (sink.running.load(std::memory_order_acquire)) return false;
    }

    for (auto& sink : m_sinks) {
        sink.wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!sink.wake) {
            for (auto& cleanup : m_sinks) {
                cleanup.running.store(false, std::memory_order_release);
                if (cleanup.wake) {
                    CloseHandle(cleanup.wake);
                    cleanup.wake = nullptr;
                }
            }
            return false;
        }
        InterlockedExchange64(&sink.dropped, 0);
        sink.running.store(true, std::memory_order_release);
    }
    InterlockedExchange64(&m_sequence, 0);
    return true;
}

std::size_t Telemetry::drain_for_test() noexcept {
    const std::size_t primary_count = drain_sink(m_sinks[0]);
    for (std::size_t index = 1; index < m_sinks.size(); ++index) {
        drain_sink(m_sinks[index]);
    }
    return primary_count;
}

std::size_t Telemetry::drain_sink_for_test(std::size_t sink_index) noexcept {
    if (sink_index >= m_sinks.size()) return 0;
    return drain_sink(m_sinks[sink_index]);
}

std::size_t Telemetry::drain_sequences_for_test(
    std::size_t sink_index, std::uint64_t* sequences,
    std::size_t capacity) noexcept {
    if (sink_index >= m_sinks.size() || !sequences || capacity == 0) return 0;
    auto& sink = m_sinks[sink_index];
    PSLIST_ENTRY list = InterlockedFlushSList(&sink.pending);
    std::array<Node*, kQueueCapacity> batch{};
    std::size_t count = 0;
    while (list && count < batch.size()) {
        PSLIST_ENTRY next = list->Next;
        batch[count++] = node_from_entry(list);
        list = next;
    }
    std::sort(batch.begin(), batch.begin() + count,
              [](const Node* left, const Node* right) {
                  return left->event.sequence < right->event.sequence;
              });
    const std::size_t copied = std::min(count, capacity);
    for (std::size_t index = 0; index < copied; ++index)
        sequences[index] = batch[index]->event.sequence;
    for (std::size_t index = 0; index < count; ++index)
        InterlockedPushEntrySList(&sink.free, &batch[index]->entry);
    while (list) {
        PSLIST_ENTRY next = list->Next;
        InterlockedPushEntrySList(&sink.free, list);
        list = next;
    }
    return copied;
}

std::size_t Telemetry::drain_sink(Sink& sink) noexcept {
    std::size_t count = 0;
    PSLIST_ENTRY list = InterlockedFlushSList(&sink.pending);
    while (list) {
        PSLIST_ENTRY next = list->Next;
        InterlockedPushEntrySList(&sink.free, list);
        list = next;
        ++count;
    }
    return count;
}

std::uint64_t Telemetry::dropped_for_test() const noexcept {
    return dropped_for_sink_for_test(0);
}

std::uint64_t Telemetry::dropped_for_sink_for_test(
    std::size_t sink_index) const noexcept {
    if (sink_index >= m_sinks.size()) return 0;
    return static_cast<std::uint64_t>(
        InterlockedCompareExchange64(
            const_cast<volatile LONG64*>(&m_sinks[sink_index].dropped), 0, 0));
}

const wchar_t* Telemetry::pipe_name_for_test(
    std::size_t sink_index) const noexcept {
    if (sink_index >= m_sinks.size()) return nullptr;
    return m_sinks[sink_index].pipe_name;
}

const char* Telemetry::session_id_for_test() const noexcept {
    return m_session_id.data();
}

void Telemetry::end_benchmark_for_test() noexcept {
    for (auto& sink : m_sinks) {
        sink.running.store(false, std::memory_order_release);
        drain_sink(sink);
        if (sink.wake) {
            CloseHandle(sink.wake);
            sink.wake = nullptr;
        }
    }
}
#endif

DWORD WINAPI Telemetry::thread_entry(void* context) {
    auto& sink = *static_cast<Sink*>(context);
    sink.owner->run(sink);
    ExitThread(0);
}

HANDLE Telemetry::connect_pipe(const Sink& sink) noexcept {
    if (!WaitNamedPipeW(sink.pipe_name, 250)) return INVALID_HANDLE_VALUE;
    return CreateFileW(sink.pipe_name, GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                       FILE_ATTRIBUTE_NORMAL, nullptr);
}

Event Telemetry::hello_event() const noexcept {
    Event event{};
    event.type = MessageType::Hello;
    event.process_id = GetCurrentProcessId();
    event.qpc_frequency = qpc_frequency();
    std::snprintf(event.build_version, sizeof(event.build_version), "%s",
                  FFB_BUILD_VERSION);
    std::snprintf(event.session_id, sizeof(event.session_id), "%s",
                  m_session_id.data());
#if defined(_WIN64)
    event.flags = 64;
#else
    event.flags = 32;
#endif
    utf8_basename(event.text, sizeof(event.text));
    return event;
}

bool Telemetry::send_frame(HANDLE pipe, const Event& event) noexcept {
    std::vector<std::uint8_t> frame;
    try {
        frame = serialize_event(event);
    } catch (...) {
        // Telemetry is strictly best-effort.  A sender-side allocation or
        // serialization failure must never escape into the host process.
        return false;
    }
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

void Telemetry::recycle_or_drop_pending(Sink& sink,
                                        bool count_as_drop) noexcept {
    PSLIST_ENTRY list = InterlockedFlushSList(&sink.pending);
    while (list) {
        PSLIST_ENTRY next = list->Next;
        if (count_as_drop) InterlockedIncrement64(&sink.dropped);
        InterlockedPushEntrySList(&sink.free, list);
        list = next;
    }
}

void Telemetry::run(Sink& sink) noexcept {
    volatile bool keep_running = true;
    while (keep_running) {
        HANDLE pipe = connect_pipe(sink);
        if (pipe == INVALID_HANDLE_VALUE) {
            recycle_or_drop_pending(sink, true);
            WaitForSingleObject(sink.wake, 250);
            continue;
        }

        Event hello = hello_event();
        if (!send_frame(pipe, hello)) {
            CloseHandle(pipe);
            recycle_or_drop_pending(sink, true);
            continue;
        }

        std::uint64_t reported_drops = 0;
        bool connected = true;
        while (connected) {
            PSLIST_ENTRY list = InterlockedFlushSList(&sink.pending);
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
                    InterlockedIncrement64(&sink.dropped);
                    InterlockedPushEntrySList(&sink.free, list);
                    list = next;
                }
            }
            std::sort(batch.begin(), batch.begin() + count,
                      [](const Node* left, const Node* right) {
                          return left->event.sequence < right->event.sequence;
                      });
            for (std::size_t i = 0; i < count && connected; ++i) {
                connected = send_frame(pipe, batch[i]->event);
                InterlockedPushEntrySList(&sink.free, &batch[i]->entry);
                if (!connected) {
                    // The failed frame and every later frame in this batch
                    // were not confirmed on the pipe.  Return their nodes
                    // and account for the loss so the next connection can
                    // publish an accurate DropNotice.
                    InterlockedIncrement64(&sink.dropped);
                    for (std::size_t unsent = i + 1; unsent < count; ++unsent) {
                        InterlockedIncrement64(&sink.dropped);
                        InterlockedPushEntrySList(&sink.free,
                                                 &batch[unsent]->entry);
                    }
                }
            }

            const auto drops = static_cast<std::uint64_t>(
                InterlockedCompareExchange64(&sink.dropped, 0, 0));
            if (connected && drops != reported_drops) {
                Event notice{};
                notice.type = MessageType::DropNotice;
                notice.process_id = GetCurrentProcessId();
                notice.dropped = static_cast<std::uint32_t>(std::min<std::uint64_t>(drops, UINT32_MAX));
                notice.qpc_ticks = qpc_now();
                bool queue_is_committed_empty = false;
                // DropNotice bypasses the bounded queue. Send it only after
                // every lower-sequence producer event has committed to this
                // sink and its pending queue is empty, so it cannot overtake
                // an older state-changing frame.
                AcquireSRWLockExclusive(&m_emit_lock);
                if (QueryDepthSList(&sink.pending) == 0) {
                    notice.sequence = static_cast<std::uint64_t>(
                        InterlockedIncrement64(&m_sequence));
                    queue_is_committed_empty = true;
                }
                ReleaseSRWLockExclusive(&m_emit_lock);
                if (queue_is_committed_empty) {
                    connected = send_frame(pipe, notice);
                    reported_drops = drops;
                }
            }
            if (count == 0 && connected) WaitForSingleObject(sink.wake, 50);
        }
        CloseHandle(pipe);
    }
}

}  // namespace ffb
