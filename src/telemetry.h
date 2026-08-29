// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include "telemetry_protocol.h"
#include <windows.h>
#include <atomic>
#include <array>
#include <cstdint>

namespace ffb {

class Telemetry final {
public:
    struct Node {
        SLIST_ENTRY entry{};
        Event event{};
    };

    static Telemetry& instance();

    // Safe to call from DirectInput8Create; it performs all one-time work
    // outside DllMain. Failure disables telemetry without affecting FFB.
    void start();
    void emit(Event event) noexcept;
    std::uint32_t next_device_id() noexcept;
    std::uint32_t next_effect_id() noexcept;

#if defined(FFB_TESTING)
    bool begin_benchmark_for_test() noexcept;
    std::size_t drain_for_test() noexcept;
    std::size_t drain_sink_for_test(std::size_t sink_index) noexcept;
    std::size_t drain_sequences_for_test(std::size_t sink_index,
                                         std::uint64_t* sequences,
                                         std::size_t capacity) noexcept;
    std::uint64_t dropped_for_test() const noexcept;
    std::uint64_t dropped_for_sink_for_test(std::size_t sink_index) const noexcept;
    const wchar_t* pipe_name_for_test(std::size_t sink_index) const noexcept;
    const char* session_id_for_test() const noexcept;
    void end_benchmark_for_test() noexcept;
#endif

private:
    static constexpr std::size_t kQueueCapacity = 1024;
    static constexpr std::size_t kSinkCount = 2;

    struct Sink {
        SLIST_HEADER free{};
        SLIST_HEADER pending{};
        std::array<Node, kQueueCapacity> nodes{};
        HANDLE wake = nullptr;
        HANDLE thread = nullptr;
        std::atomic<bool> running{false};
        volatile LONG64 dropped = 0;
        const wchar_t* pipe_name = nullptr;
        Telemetry* owner = nullptr;
    };

    Telemetry();
    static DWORD WINAPI thread_entry(void* context);
    void run(Sink& sink) noexcept;
    void enqueue(Sink& sink, const Event& event) noexcept;
    bool send_frame(HANDLE pipe, const Event& event) noexcept;
    HANDLE connect_pipe(const Sink& sink) noexcept;
    Event hello_event() const noexcept;
    void recycle_or_drop_pending(Sink& sink, bool count_as_drop) noexcept;
    std::size_t drain_sink(Sink& sink) noexcept;

    std::array<Sink, kSinkCount> m_sinks{};
    // Sequence allocation and publication to both sinks form one commit.
    // Without this lock, a producer that obtained sequence N could be
    // pre-empted while producer N+1 was already queued and transmitted.
    SRWLOCK m_emit_lock = SRWLOCK_INIT;
    std::atomic_flag m_starting = ATOMIC_FLAG_INIT;
    volatile LONG64 m_sequence = 0;
    volatile LONG m_next_device = 0;
    volatile LONG m_next_effect = 0;
    std::array<char, 32> m_session_id{};
};

}  // namespace ffb
