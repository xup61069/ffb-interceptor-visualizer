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

private:
    static constexpr std::size_t kQueueCapacity = 1024;

    Telemetry();
    static DWORD WINAPI thread_entry(void* context);
    void run() noexcept;
    bool send_frame(HANDLE pipe, const Event& event) noexcept;
    HANDLE connect_pipe() noexcept;
    Event hello_event() const noexcept;
    void recycle_or_drop_pending(bool count_as_drop) noexcept;

    SLIST_HEADER m_free{};
    SLIST_HEADER m_pending{};
    std::array<Node, kQueueCapacity> m_nodes{};
    HANDLE m_wake = nullptr;
    HANDLE m_thread = nullptr;
    std::atomic<bool> m_running{false};
    volatile LONG64 m_sequence = 0;
    volatile LONG64 m_dropped = 0;
    volatile LONG m_next_device = 0;
    volatile LONG m_next_effect = 0;
};

}  // namespace ffb
