// SPDX-License-Identifier: GPL-3.0-only
#include "telemetry_protocol.h"

#include <cassert>
#include <cstdint>

int main() {
    ffb::Event event{};
    event.type = ffb::MessageType::EffectParametersChanged;
    event.effect_kind = ffb::EffectKind::Constant;
    event.sequence = 7;
    event.qpc_ticks = 1234;
    event.process_id = 42;
    event.device_id = 1;
    event.effect_id = 2;
    event.magnitude = -10000;
    event.axis_count = 1;
    event.axes[0] = 0;
    event.directions[0] = 9000;
    auto frame = ffb::serialize_event(event);
    assert(frame.size() >= 32);
    assert(ffb::valid_frame(frame.data(), frame.size()));
    frame[8] ^= 0x01;
    assert(!ffb::valid_frame(frame.data(), frame.size()));
    return 0;
}
