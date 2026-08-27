// SPDX-License-Identifier: GPL-3.0-only
#include "telemetry.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <vector>

int main() {
    using Clock = std::chrono::steady_clock;
    constexpr std::size_t kSamples = 20'000;
    constexpr std::size_t kBatchSize = 128;
    constexpr double kMaxP99Microseconds = 100.0;

    auto& telemetry = ffb::Telemetry::instance();
    assert(telemetry.begin_benchmark_for_test());

    ffb::Event event{};
    event.type = ffb::MessageType::EffectParametersChanged;
    event.effect_kind = ffb::EffectKind::Constant;
    event.magnitude = 5'000;

    std::vector<double> samples;
    samples.reserve(kSamples);
    const auto wall_start = Clock::now();
    std::size_t expected_in_batch = 0;
    for (std::size_t index = 0; index < kSamples; ++index) {
        const auto started = Clock::now();
        telemetry.emit(event);
        const auto finished = Clock::now();
        samples.push_back(
            std::chrono::duration<double, std::micro>(finished - started).count());
        ++expected_in_batch;
        if (expected_in_batch == kBatchSize || index + 1 == kSamples) {
            assert(telemetry.drain_for_test() == expected_in_batch);
            expected_in_batch = 0;
        }
    }
    const double elapsed_seconds =
        std::chrono::duration<double>(Clock::now() - wall_start).count();

    assert(telemetry.dropped_for_test() == 0);
    telemetry.end_benchmark_for_test();

    std::sort(samples.begin(), samples.end());
    const std::size_t p99_index =
        static_cast<std::size_t>(std::ceil(samples.size() * 0.99)) - 1;
    const double p99_microseconds = samples[p99_index];
    const double events_per_second =
        static_cast<double>(kSamples) / elapsed_seconds;
    std::printf("proxy hot path: %.0f events/s, p99 %.3f us\n",
                events_per_second, p99_microseconds);
    assert(events_per_second >= 1'000.0);
    assert(p99_microseconds < kMaxP99Microseconds);
    return 0;
}
