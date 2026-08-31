// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <windows.h>
#include <dinput.h>
#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace ffb {

constexpr std::uint16_t kProtocolVersion = 1;
constexpr std::uint32_t kMaxFrameSize = 64u * 1024u;
constexpr std::size_t kMaxAxes = 8;

// EffectCreated has no DirectInput call flags of its own, so protocol v1 can
// use two otherwise-unused header bits to describe whether CreateEffect's
// optional DIEFFECT pointer was supplied.  The meaning is deliberately
// limited to EffectCreated; EffectParametersChanged keeps its DIEP_* flags
// unchanged.
constexpr std::uint32_t kEffectCreatedParametersAbsentFlag = 0x08000000u;
constexpr std::uint32_t kEffectCreatedParametersPresentFlag = 0x10000000u;
constexpr std::uint32_t kEffectCreatedParametersPresenceMask =
    kEffectCreatedParametersAbsentFlag | kEffectCreatedParametersPresentFlag;

enum class MessageType : std::uint16_t {
    Hello = 1,
    DeviceCreated = 2,
    DevicePropertyChanged = 3,
    EffectCreated = 4,
    EffectParametersChanged = 5,
    EffectCommand = 6,
    DeviceCommand = 7,
    DropNotice = 8,
};

enum class EffectKind : std::uint16_t {
    Unknown = 0,
    Constant = 1,
    Ramp = 2,
    Square = 3,
    Sine = 4,
    Triangle = 5,
    SawtoothUp = 6,
    SawtoothDown = 7,
    Spring = 8,
    Damper = 9,
    Inertia = 10,
    Friction = 11,
    Custom = 12,
};

enum class EffectCommand : std::uint16_t {
    Download = 1,
    Start = 2,
    Stop = 3,
    Unload = 4,
    Release = 5,
};

enum class EffectParameterPresence : std::uint8_t {
    // Legacy protocol-v1 producers emitted neither presence bit. Consumers
    // retain their conservative legacy interpretation for those frames.
    Unknown = 0,
    Absent = 1,
    Present = 2,
};

struct ConditionSample {
    std::int32_t offset = 0;
    std::int32_t positive_coefficient = 0;
    std::int32_t negative_coefficient = 0;
    std::uint32_t positive_saturation = 0;
    std::uint32_t negative_saturation = 0;
    std::int32_t dead_band = 0;
};

// Fixed-size event owned by the proxy queue. It deliberately contains no
// pointers, process paths, device serials, or arbitrary custom-effect bytes.
struct Event {
    MessageType type = MessageType::DropNotice;
    EffectKind effect_kind = EffectKind::Unknown;
    EffectParameterPresence effect_parameter_presence =
        EffectParameterPresence::Unknown;
    std::uint16_t command = 0;
    std::uint32_t flags = 0;
    std::uint64_t sequence = 0;
    std::uint64_t qpc_ticks = 0;
    std::uint32_t process_id = 0;
    std::uint32_t device_id = 0;
    std::uint32_t effect_id = 0;
    GUID effect_guid{};
    HRESULT hresult = S_OK;
    std::uint32_t di_flags = 0;
    std::uint32_t duration = 0;
    std::uint32_t sample_period = 0;
    std::uint32_t gain = 0;
    std::uint32_t start_delay = 0;
    std::uint32_t trigger_button = 0;
    std::uint32_t trigger_repeat = 0;
    std::uint32_t iterations = 0;
    std::uint32_t envelope_attack_level = 0;
    std::uint32_t envelope_attack_time = 0;
    std::uint32_t envelope_fade_level = 0;
    std::uint32_t envelope_fade_time = 0;
    std::uint32_t qpc_frequency = 0;
    std::uint32_t property_id = 0;
    std::uint32_t dropped = 0;
    std::int32_t magnitude = 0;
    std::int32_t ramp_start = 0;
    std::int32_t ramp_end = 0;
    std::int32_t periodic_magnitude = 0;
    std::int32_t periodic_offset = 0;
    std::int32_t periodic_phase = 0;
    std::int32_t periodic_period = 0;
    std::uint32_t axis_count = 0;
    std::array<std::int32_t, kMaxAxes> axes{};
    std::array<std::int32_t, kMaxAxes> directions{};
    std::uint32_t condition_count = 0;
    std::array<ConditionSample, kMaxAxes> conditions{};
    std::uint32_t type_specific_size = 0;
    bool custom_redacted = false;
    char build_version[32]{};
    char session_id[32]{};
    char text[64]{};
};

std::uint64_t qpc_now();
std::uint32_t qpc_frequency();
EffectKind effect_kind_from_guid(REFGUID guid);
void fill_effect_parameters(Event& event, const DIEFFECT* effect) noexcept;
std::size_t copy_utf8_truncated(char* out, std::size_t capacity,
                                const std::string& text) noexcept;
std::size_t copy_utf8_truncated(char* out, std::size_t capacity,
                                const char* text, std::size_t size) noexcept;

// The wire header is always 32 bytes. All fields are explicitly serialized
// little-endian; no compiler packing or ABI assumptions cross the pipe.
std::vector<std::uint8_t> serialize_event(const Event& event);
bool valid_frame(const std::uint8_t* data, std::size_t size);

}  // namespace ffb
