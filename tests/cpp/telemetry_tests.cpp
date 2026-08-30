// SPDX-License-Identifier: GPL-3.0-only
#include "telemetry.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <algorithm>
#include <cassert>
#include <atomic>
#include <cstdint>
#include <cwchar>
#include <thread>
#include <vector>

int main() {
    auto& telemetry = ffb::Telemetry::instance();
    assert(telemetry.session_id_for_test() != nullptr);
    assert(telemetry.session_id_for_test()[0] != '\0');

    assert(std::wcscmp(telemetry.pipe_name_for_test(0),
                       L"\\\\.\\pipe\\ffb-interceptor-v1") == 0);
    assert(std::wcscmp(telemetry.pipe_name_for_test(1),
                       L"\\\\.\\pipe\\ffb-interceptor-simhub-v1") == 0);
    assert(telemetry.pipe_name_for_test(2) == nullptr);

    assert(telemetry.begin_benchmark_for_test());

    ffb::Event event{};
    event.type = ffb::MessageType::EffectParametersChanged;
    event.effect_kind = ffb::EffectKind::Constant;
    event.magnitude = 9'900;

    // Keep the viewer sink flowing while deliberately never draining the
    // SimHub sink.  A full/stalled SimHub queue must not cause the viewer
    // queue to drop or block telemetry.
    constexpr std::size_t kEventCount = 4'000;
    constexpr std::size_t kViewerDrainBatch = 64;
    std::size_t viewer_received = 0;
    for (std::size_t index = 0; index < kEventCount; ++index) {
        telemetry.emit(event);
        if ((index + 1) % kViewerDrainBatch == 0) {
            viewer_received += telemetry.drain_sink_for_test(0);
        }
    }
    viewer_received += telemetry.drain_sink_for_test(0);

    const std::size_t simhub_received = telemetry.drain_sink_for_test(1);
    const std::uint64_t viewer_dropped =
        telemetry.dropped_for_sink_for_test(0);
    const std::uint64_t simhub_dropped =
        telemetry.dropped_for_sink_for_test(1);

    assert(viewer_received == kEventCount);
    assert(viewer_dropped == 0);
    assert(simhub_dropped > 0);
    assert(static_cast<std::uint64_t>(simhub_received) + simhub_dropped ==
           static_cast<std::uint64_t>(kEventCount));

    telemetry.end_benchmark_for_test();

    // Multiple DirectInput callers may emit concurrently. Drain while they
    // publish to exercise ordering across separate flush batches.
    assert(telemetry.begin_benchmark_for_test());
    constexpr std::size_t kProducerCount = 4;
    constexpr std::size_t kEventsPerProducer = 200;
    constexpr std::size_t kConcurrentCount =
        kProducerCount * kEventsPerProducer;
    std::atomic<std::size_t> finished{0};
    std::vector<std::uint64_t> viewer_sequences;
    std::vector<std::uint64_t> simhub_sequences;
    viewer_sequences.reserve(kConcurrentCount);
    simhub_sequences.reserve(kConcurrentCount);
    std::thread drainer([&] {
        std::array<std::uint64_t, 1024> batch{};
        while (finished.load(std::memory_order_acquire) != kProducerCount ||
               viewer_sequences.size() < kConcurrentCount ||
               simhub_sequences.size() < kConcurrentCount) {
            auto count = telemetry.drain_sequences_for_test(
                0, batch.data(), batch.size());
            viewer_sequences.insert(viewer_sequences.end(), batch.begin(),
                                    batch.begin() + count);
            count = telemetry.drain_sequences_for_test(
                1, batch.data(), batch.size());
            simhub_sequences.insert(simhub_sequences.end(), batch.begin(),
                                    batch.begin() + count);
            std::this_thread::yield();
        }
    });
    std::array<std::thread, kProducerCount> producers;
    for (auto& producer : producers) {
        producer = std::thread([&] {
            for (std::size_t index = 0; index < kEventsPerProducer; ++index)
                telemetry.emit(event);
            finished.fetch_add(1, std::memory_order_release);
        });
    }
    for (auto& producer : producers) producer.join();
    drainer.join();
    assert(viewer_sequences.size() == kConcurrentCount);
    assert(simhub_sequences.size() == kConcurrentCount);
    assert(std::is_sorted(viewer_sequences.begin(), viewer_sequences.end()));
    assert(std::is_sorted(simhub_sequences.begin(), simhub_sequences.end()));
    assert(std::adjacent_find(viewer_sequences.begin(),
                              viewer_sequences.end()) ==
           viewer_sequences.end());
    assert(viewer_sequences == simhub_sequences);
    assert(telemetry.dropped_for_sink_for_test(0) == 0);
    assert(telemetry.dropped_for_sink_for_test(1) == 0);
    telemetry.end_benchmark_for_test();
    return 0;
}
