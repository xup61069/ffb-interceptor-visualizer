// SPDX-License-Identifier: GPL-3.0-only
#include "telemetry_protocol.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace {

std::vector<std::uint8_t> load_golden_fixture() {
    std::ifstream stream(std::string(FFB_SOURCE_DIR) +
                         "/tests/fixtures/event_v1.hex");
    const std::string text((std::istreambuf_iterator<char>(stream)),
                           std::istreambuf_iterator<char>());
    std::string hex;
    for (const unsigned char value : text) {
        if (!std::isspace(value)) hex.push_back(static_cast<char>(value));
    }
    assert(!hex.empty() && hex.size() % 2 == 0);
    std::vector<std::uint8_t> bytes;
    bytes.reserve(hex.size() / 2);
    for (std::size_t i = 0; i < hex.size(); i += 2) {
        unsigned int value = 0;
        assert(sscanf_s(hex.c_str() + i, "%2x", &value) == 1);
        bytes.push_back(static_cast<std::uint8_t>(value));
    }
    return bytes;
}

std::uint32_t read_u32(const std::vector<std::uint8_t>& bytes,
                       std::size_t offset) {
    assert(bytes.size() >= 4 && offset <= bytes.size() - 4);
    return static_cast<std::uint32_t>(bytes[offset]) |
           (static_cast<std::uint32_t>(bytes[offset + 1]) << 8) |
           (static_cast<std::uint32_t>(bytes[offset + 2]) << 16) |
           (static_cast<std::uint32_t>(bytes[offset + 3]) << 24);
}

}  // namespace

int main() {
    std::string emoji_name;
    for (int index = 0; index < 16; ++index)
        emoji_name.append("\xF0\x9F\x98\x80");
    char truncated_name[64]{};
    assert(ffb::copy_utf8_truncated(truncated_name, sizeof(truncated_name),
                                    emoji_name) == 60);
    assert(std::string(truncated_name) == emoji_name.substr(0, 60));
    assert(ffb::copy_utf8_truncated(truncated_name, sizeof(truncated_name),
                                    std::string(100, 'a')) == 63);
    assert(std::string(truncated_name) == std::string(63, 'a'));
    const std::string long_non_ascii_basename = emoji_name + emoji_name + ".exe";
    assert(ffb::copy_utf8_truncated(
               truncated_name, sizeof(truncated_name),
               long_non_ascii_basename.data(), long_non_ascii_basename.size()) ==
           60);
    assert(std::string(truncated_name) == emoji_name.substr(0, 60));

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

    // Presence is carried in EffectCreated's existing header flags, keeping
    // the protocol-v1 layout stable. A legal button zero remains payload data
    // and cannot be confused with an absent DIEFFECT pointer.
    ffb::Event absent_parameters{};
    absent_parameters.type = ffb::MessageType::EffectCreated;
    absent_parameters.effect_parameter_presence =
        ffb::EffectParameterPresence::Absent;
    absent_parameters.trigger_button = 0;
    const auto absent_frame = ffb::serialize_event(absent_parameters);
    assert(read_u32(absent_frame, 12) ==
           ffb::kEffectCreatedParametersAbsentFlag);

    ffb::Event present_parameters = absent_parameters;
    present_parameters.effect_parameter_presence =
        ffb::EffectParameterPresence::Present;
    const auto present_frame = ffb::serialize_event(present_parameters);
    assert(read_u32(present_frame, 12) ==
           ffb::kEffectCreatedParametersPresentFlag);

    // Legacy protocol-v1 events used Flags=0. Preserve that representation
    // for Unknown so a newer consumer can select its conservative fallback.
    ffb::Event legacy_presence = absent_parameters;
    legacy_presence.effect_parameter_presence =
        ffb::EffectParameterPresence::Unknown;
    const auto legacy_presence_frame = ffb::serialize_event(legacy_presence);
    assert(read_u32(legacy_presence_frame, 12) == 0);

    // Presence bits are context-specific and must never alter SetParameters'
    // DIEP_* flags.
    ffb::Event changed_presence{};
    changed_presence.type = ffb::MessageType::EffectParametersChanged;
    changed_presence.flags = DIEP_GAIN;
    changed_presence.effect_parameter_presence =
        ffb::EffectParameterPresence::Present;
    const auto changed_presence_frame = ffb::serialize_event(changed_presence);
    assert(read_u32(changed_presence_frame, 12) == DIEP_GAIN);

    ffb::Event opaque{};
    opaque.effect_kind = ffb::EffectKind::Custom;
    DIEFFECT empty_effect{};
    empty_effect.dwSize = sizeof(empty_effect);
    ffb::fill_effect_parameters(opaque, &empty_effect);
    assert(opaque.type_specific_size == 0);
    assert(opaque.custom_redacted);

    // A partial SetParameters call must not touch pointer fields that are not
    // selected by DIEP_* flags.  Games commonly leave those fields unset.
    ffb::Event partial{};
    partial.type = ffb::MessageType::EffectParametersChanged;
    partial.effect_kind = ffb::EffectKind::Constant;
    partial.flags = DIEP_GAIN;
    DIEFFECT partial_effect{};
    partial_effect.dwSize = sizeof(partial_effect);
    partial_effect.dwGain = 4321;
    partial_effect.cAxes = 8;
    partial_effect.rgdwAxes = reinterpret_cast<LPDWORD>(1);
    partial_effect.rglDirection = reinterpret_cast<LPLONG>(1);
    partial_effect.lpvTypeSpecificParams = reinterpret_cast<LPVOID>(1);
    partial_effect.cbTypeSpecificParams = sizeof(DICONSTANTFORCE);
    ffb::fill_effect_parameters(partial, &partial_effect);
    assert(partial.gain == 4321);
    assert(partial.axis_count == 0);
    assert(partial.type_specific_size == 0);
    assert(partial.magnitude == 0);

    ffb::Event legacy{};
    legacy.type = ffb::MessageType::EffectCreated;
    legacy.effect_kind = ffb::EffectKind::Constant;
    DIEFFECT_DX5 legacy_effect{};
    legacy_effect.dwSize = sizeof(legacy_effect);
    legacy_effect.dwGain = 9876;
    ffb::fill_effect_parameters(
        legacy, reinterpret_cast<const DIEFFECT*>(&legacy_effect));
    assert(legacy.gain == 9876);
    assert(legacy.start_delay == 0);

    ffb::Event golden{};
    golden.type = ffb::MessageType::EffectParametersChanged;
    golden.effect_kind = ffb::EffectKind::Spring;
    golden.command = static_cast<std::uint16_t>(ffb::EffectCommand::Start);
    golden.flags = 165;
    golden.sequence = 7;
    golden.qpc_ticks = 123456789;
    golden.process_id = 4242;
    golden.qpc_frequency = 10000000;
    golden.device_id = 11;
    golden.effect_id = 22;
    for (std::size_t i = 0; i < sizeof(GUID); ++i) {
        reinterpret_cast<std::uint8_t*>(&golden.effect_guid)[i] =
            static_cast<std::uint8_t>(i);
    }
    golden.hresult = -123;
    golden.di_flags = 0;
    golden.duration = 1;
    golden.sample_period = 2;
    golden.gain = 3;
    golden.start_delay = 4;
    golden.trigger_button = 5;
    golden.trigger_repeat = 6;
    golden.iterations = 7;
    golden.envelope_attack_level = 8;
    golden.envelope_attack_time = 9;
    golden.envelope_fade_level = 10;
    golden.envelope_fade_time = 11;
    golden.property_id = 12;
    golden.dropped = 13;
    golden.magnitude = -10;
    golden.ramp_start = -20;
    golden.ramp_end = -30;
    golden.periodic_magnitude = -40;
    golden.periodic_offset = -50;
    golden.periodic_phase = -60;
    golden.periodic_period = -70;
    golden.axis_count = 2;
    golden.axes[0] = 1;
    golden.axes[1] = -2;
    golden.directions[0] = 3;
    golden.directions[1] = -4;
    golden.condition_count = 1;
    for (auto& condition : golden.conditions) {
        condition.offset = -1;
        condition.positive_coefficient = 2;
        condition.negative_coefficient = 3;
        condition.positive_saturation = 4;
        condition.negative_saturation = 5;
        condition.dead_band = 6;
    }
    golden.type_specific_size = 24;
    strcpy_s(golden.build_version, "0.1.0");
    strcpy_s(golden.session_id, "fixture-session");
    strcpy_s(golden.text, "fixture.exe");
    const auto fixture = load_golden_fixture();
    assert(ffb::serialize_event(golden) == fixture);
    return 0;
}
