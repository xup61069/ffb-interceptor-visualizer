// SPDX-License-Identifier: GPL-3.0-only
#include "telemetry_protocol.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdint>
#include <cstring>

int main() {
    ffb::Event event{};
    event.type = ffb::MessageType::EffectParametersChanged;
    event.effect_kind = ffb::EffectKind::Constant;
    event.command = static_cast<std::uint16_t>(ffb::EffectCommand::Start);
    event.sequence = 7;
    event.qpc_ticks = 1234;
    event.process_id = 42;
    event.device_id = 1;
    event.effect_id = 2;
    event.magnitude = -10000;
    event.duration = 0xFFFFFFFFu;  // DirectInput's DI_INFINITE sentinel
    event.gain = 5000;
    event.envelope_attack_level = 100;
    event.envelope_attack_time = 200;
    event.envelope_fade_level = 300;
    event.envelope_fade_time = 400;
    event.axis_count = 1;
    event.axes[0] = 0;
    event.directions[0] = 9000;
    auto frame = ffb::serialize_event(event);
    assert(frame.size() >= 32);
    assert(ffb::valid_frame(frame.data(), frame.size()));
    assert(frame.size() <= ffb::kMaxFrameSize);
    assert(std::memcmp(frame.data(), "FFB1", 4) == 0);
    assert(frame[frame.size() - 4] == static_cast<std::uint8_t>(ffb::EffectKind::Constant));
    assert(frame[frame.size() - 3] == 0);
    assert(frame[frame.size() - 2] == static_cast<std::uint8_t>(ffb::EffectCommand::Start));
    assert(frame[frame.size() - 1] == 0);
    assert(ffb::valid_frame(nullptr, 0) == false);
    frame[4] = 2;
    assert(!ffb::valid_frame(frame.data(), frame.size()));
    frame[4] = 1;
    frame[8] ^= 0x01;
    assert(!ffb::valid_frame(frame.data(), frame.size()));
    return 0;
}
