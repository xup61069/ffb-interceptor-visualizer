// SPDX-License-Identifier: GPL-3.0-only
#include "telemetry_protocol.h"

#include <algorithm>
#include <cstddef>
#include <cstring>

namespace ffb {
namespace {

void put_u16(std::vector<std::uint8_t>& out, std::uint16_t value) {
    out.push_back(static_cast<std::uint8_t>(value));
    out.push_back(static_cast<std::uint8_t>(value >> 8));
}

void put_u32(std::vector<std::uint8_t>& out, std::uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) out.push_back(static_cast<std::uint8_t>(value >> (8 * i)));
}

void put_u64(std::vector<std::uint8_t>& out, std::uint64_t value) {
    for (unsigned i = 0; i < 8; ++i) out.push_back(static_cast<std::uint8_t>(value >> (8 * i)));
}

void put_i32(std::vector<std::uint8_t>& out, std::int32_t value) {
    put_u32(out, static_cast<std::uint32_t>(value));
}

void put_guid(std::vector<std::uint8_t>& out, const GUID& guid) {
    const auto* bytes = reinterpret_cast<const std::uint8_t*>(&guid);
    out.insert(out.end(), bytes, bytes + sizeof(GUID));
}

void put_condition(std::vector<std::uint8_t>& out, const ConditionSample& condition) {
    put_i32(out, condition.offset);
    put_i32(out, condition.positive_coefficient);
    put_i32(out, condition.negative_coefficient);
    put_u32(out, condition.positive_saturation);
    put_u32(out, condition.negative_saturation);
    put_i32(out, condition.dead_band);
}

void put_string(std::vector<std::uint8_t>& out, const char* text) {
    const auto length = static_cast<std::uint16_t>(std::min<std::size_t>(strnlen_s(text, 63), 63));
    put_u16(out, length);
    out.insert(out.end(), text, text + length);
}

void put_fixed_string(std::vector<std::uint8_t>& out, const char* text, std::size_t capacity) {
    const auto* begin = reinterpret_cast<const std::uint8_t*>(text);
    out.insert(out.end(), begin, begin + capacity);
}

}  // namespace

std::uint64_t qpc_now() {
    LARGE_INTEGER value{};
    QueryPerformanceCounter(&value);
    return static_cast<std::uint64_t>(value.QuadPart);
}

std::uint32_t qpc_frequency() {
    LARGE_INTEGER value{};
    QueryPerformanceFrequency(&value);
    return value.QuadPart > 0 ? static_cast<std::uint32_t>(value.QuadPart) : 1u;
}

EffectKind effect_kind_from_guid(REFGUID guid) {
    if (IsEqualGUID(guid, GUID_ConstantForce)) return EffectKind::Constant;
    if (IsEqualGUID(guid, GUID_RampForce)) return EffectKind::Ramp;
    if (IsEqualGUID(guid, GUID_Square)) return EffectKind::Square;
    if (IsEqualGUID(guid, GUID_Sine)) return EffectKind::Sine;
    if (IsEqualGUID(guid, GUID_Triangle)) return EffectKind::Triangle;
    if (IsEqualGUID(guid, GUID_SawtoothUp)) return EffectKind::SawtoothUp;
    if (IsEqualGUID(guid, GUID_SawtoothDown)) return EffectKind::SawtoothDown;
    if (IsEqualGUID(guid, GUID_Spring)) return EffectKind::Spring;
    if (IsEqualGUID(guid, GUID_Damper)) return EffectKind::Damper;
    if (IsEqualGUID(guid, GUID_Inertia)) return EffectKind::Inertia;
    if (IsEqualGUID(guid, GUID_Friction)) return EffectKind::Friction;
    if (IsEqualGUID(guid, GUID_CustomForce)) return EffectKind::Custom;
    return EffectKind::Unknown;
}

std::size_t copy_utf8_truncated(char* out, std::size_t capacity,
                                const std::string& text) noexcept {
    return copy_utf8_truncated(out, capacity, text.data(), text.size());
}

std::size_t copy_utf8_truncated(char* out, std::size_t capacity,
                                const char* text, std::size_t size) noexcept {
    if (!out || capacity == 0) return 0;
    if (!text && size != 0) {
        out[0] = '\0';
        return 0;
    }
    std::size_t length = std::min(size, capacity - 1);
    if (length < size) {
        // If the first excluded byte is a UTF-8 continuation byte, the
        // prefix ends inside a multi-byte code point. Drop that whole code
        // point so strict consumers never reject the frame.
        while (length > 0 &&
               (static_cast<unsigned char>(text[length]) & 0xC0u) == 0x80u) {
            --length;
        }
    }
    if (length != 0) std::memcpy(out, text, length);
    out[length] = '\0';
    return length;
}

void fill_effect_parameters(Event& event, const DIEFFECT* effect) noexcept {
    if (!effect) return;
    __try {
        // DirectInput accepts the legacy DX5-sized structure.  Never read
        // dwStartDelay or any pointer fields before the caller-provided size
        // proves that the common layout is present.
        if (effect->dwSize < sizeof(DIEFFECT_DX5)) {
            event.custom_redacted = event.effect_kind == EffectKind::Custom ||
                                    event.effect_kind == EffectKind::Unknown;
            return;
        }
        const bool capture_all = event.type == MessageType::EffectCreated;
        const auto requested = event.flags;
        const auto captures = [capture_all, requested](DWORD flag) noexcept {
            return capture_all || (requested & flag) != 0;
        };
        event.di_flags = effect->dwFlags;
        if (captures(DIEP_DURATION)) event.duration = effect->dwDuration;
        if (captures(DIEP_SAMPLEPERIOD)) event.sample_period = effect->dwSamplePeriod;
        if (captures(DIEP_GAIN)) event.gain = effect->dwGain;
        if (captures(DIEP_STARTDELAY) && effect->dwSize >= sizeof(DIEFFECT))
            event.start_delay = effect->dwStartDelay;
        if (captures(DIEP_TRIGGERBUTTON)) event.trigger_button = effect->dwTriggerButton;
        if (captures(DIEP_TRIGGERREPEATINTERVAL))
            event.trigger_repeat = effect->dwTriggerRepeatInterval;
        if (captures(DIEP_AXES) || captures(DIEP_DIRECTION)) {
            event.axis_count = static_cast<std::uint32_t>(
                std::min<std::size_t>(effect->cAxes, kMaxAxes));
        }
        if (captures(DIEP_AXES) && effect->rgdwAxes) {
            for (std::size_t i = 0; i < event.axis_count; ++i)
                event.axes[i] = static_cast<std::int32_t>(effect->rgdwAxes[i]);
        }
        if (captures(DIEP_DIRECTION) && effect->rglDirection) {
            for (std::size_t i = 0; i < event.axis_count; ++i)
                event.directions[i] = effect->rglDirection[i];
        }
        if (captures(DIEP_ENVELOPE) && effect->lpEnvelope &&
            effect->lpEnvelope->dwSize >= sizeof(DIENVELOPE)) {
            event.envelope_attack_level = effect->lpEnvelope->dwAttackLevel;
            event.envelope_attack_time = effect->lpEnvelope->dwAttackTime;
            event.envelope_fade_level = effect->lpEnvelope->dwFadeLevel;
            event.envelope_fade_time = effect->lpEnvelope->dwFadeTime;
        }
        if (event.effect_kind == EffectKind::Custom ||
            event.effect_kind == EffectKind::Unknown) {
            event.custom_redacted = true;
        }
        if (!captures(DIEP_TYPESPECIFICPARAMS)) return;
        event.type_specific_size = effect->cbTypeSpecificParams;
        if (!effect->lpvTypeSpecificParams || event.type_specific_size == 0) {
            // Custom/unknown effects never expose their opaque bytes.  Keep
            // the redaction bit set even when the game supplied a null or
            // zero-length pointer so consumers cannot mistake the absence of
            // a payload for an inspected custom effect.
            if (event.effect_kind == EffectKind::Custom ||
                event.effect_kind == EffectKind::Unknown) {
                event.custom_redacted = true;
            }
            return;
        }
        switch (event.effect_kind) {
            case EffectKind::Constant:
                if (event.type_specific_size >= sizeof(DICONSTANTFORCE))
                    event.magnitude = static_cast<DICONSTANTFORCE*>(effect->lpvTypeSpecificParams)->lMagnitude;
                break;
            case EffectKind::Ramp:
                if (event.type_specific_size >= sizeof(DIRAMPFORCE)) {
                    const auto* value = static_cast<const DIRAMPFORCE*>(effect->lpvTypeSpecificParams);
                    event.ramp_start = value->lStart;
                    event.ramp_end = value->lEnd;
                }
                break;
            case EffectKind::Square:
            case EffectKind::Sine:
            case EffectKind::Triangle:
            case EffectKind::SawtoothUp:
            case EffectKind::SawtoothDown:
                if (event.type_specific_size >= sizeof(DIPERIODIC)) {
                    const auto* value = static_cast<const DIPERIODIC*>(effect->lpvTypeSpecificParams);
                    event.periodic_magnitude = static_cast<std::int32_t>(value->dwMagnitude);
                    event.periodic_offset = value->lOffset;
                    event.periodic_phase = static_cast<std::int32_t>(value->dwPhase);
                    event.periodic_period = static_cast<std::int32_t>(value->dwPeriod);
                    event.magnitude = event.periodic_magnitude;
                }
                break;
            case EffectKind::Spring:
            case EffectKind::Damper:
            case EffectKind::Inertia:
            case EffectKind::Friction: {
                if (event.type_specific_size >= sizeof(DICONDITION)) {
                    const auto* values = static_cast<const DICONDITION*>(effect->lpvTypeSpecificParams);
                    const std::size_t available = event.type_specific_size / sizeof(DICONDITION);
                    const std::size_t count = std::min<std::size_t>(
                        event.axis_count == 0 ? available : event.axis_count, kMaxAxes);
                    event.condition_count = static_cast<std::uint32_t>(std::min(count, available));
                    for (std::size_t i = 0; i < event.condition_count; ++i) {
                        event.conditions[i].offset = values[i].lOffset;
                        event.conditions[i].positive_coefficient = values[i].lPositiveCoefficient;
                        event.conditions[i].negative_coefficient = values[i].lNegativeCoefficient;
                        event.conditions[i].positive_saturation = values[i].dwPositiveSaturation;
                        event.conditions[i].negative_saturation = values[i].dwNegativeSaturation;
                        event.conditions[i].dead_band = values[i].lDeadBand;
                    }
                }
                break;
            }
            default:
                event.custom_redacted = true;
                break;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        event.custom_redacted = true;
        event.axis_count = 0;
        event.condition_count = 0;
    }
}

std::vector<std::uint8_t> serialize_event(const Event& event) {
    std::vector<std::uint8_t> payload;
    payload.reserve(512);
    put_u32(payload, event.process_id);
    put_u32(payload, event.qpc_frequency);
    put_u32(payload, event.device_id);
    put_u32(payload, event.effect_id);
    put_guid(payload, event.effect_guid);
    put_i32(payload, event.hresult);
    put_u32(payload, event.di_flags);
    put_u32(payload, event.duration);
    put_u32(payload, event.sample_period);
    put_u32(payload, event.gain);
    put_u32(payload, event.start_delay);
    put_u32(payload, event.trigger_button);
    put_u32(payload, event.trigger_repeat);
    put_u32(payload, event.iterations);
    put_u32(payload, event.envelope_attack_level);
    put_u32(payload, event.envelope_attack_time);
    put_u32(payload, event.envelope_fade_level);
    put_u32(payload, event.envelope_fade_time);
    put_u32(payload, event.property_id);
    put_u32(payload, event.dropped);
    put_i32(payload, event.magnitude);
    put_i32(payload, event.ramp_start);
    put_i32(payload, event.ramp_end);
    put_i32(payload, event.periodic_magnitude);
    put_i32(payload, event.periodic_offset);
    put_i32(payload, event.periodic_phase);
    put_i32(payload, event.periodic_period);
    put_u32(payload, event.axis_count);
    for (std::size_t i = 0; i < kMaxAxes; ++i) put_i32(payload, event.axes[i]);
    for (std::size_t i = 0; i < kMaxAxes; ++i) put_i32(payload, event.directions[i]);
    put_u32(payload, event.condition_count);
    for (std::size_t i = 0; i < kMaxAxes; ++i) put_condition(payload, event.conditions[i]);
    put_u32(payload, event.type_specific_size);
    put_u32(payload, event.custom_redacted ? 1u : 0u);
    put_fixed_string(payload, event.build_version, sizeof(event.build_version));
    put_fixed_string(payload, event.session_id, sizeof(event.session_id));
    put_string(payload, event.text);
    // Keep effect kind and command at the end so v1 readers can still parse
    // older frames and treat these optional fields as Unknown/zero.
    put_u16(payload, static_cast<std::uint16_t>(event.effect_kind));
    put_u16(payload, event.command);

    std::vector<std::uint8_t> frame;
    frame.reserve(32 + payload.size());
    frame.insert(frame.end(), {'F', 'F', 'B', '1'});
    put_u16(frame, kProtocolVersion);
    put_u16(frame, static_cast<std::uint16_t>(event.type));
    put_u32(frame, static_cast<std::uint32_t>(32 + payload.size()));
    put_u32(frame, event.flags);
    put_u64(frame, event.sequence);
    put_u64(frame, event.qpc_ticks);
    frame.insert(frame.end(), payload.begin(), payload.end());
    return frame;
}

bool valid_frame(const std::uint8_t* data, std::size_t size) {
    if (data == nullptr || size < 32 || size > kMaxFrameSize) return false;
    if (std::memcmp(data, "FFB1", 4) != 0) return false;
    const auto version = static_cast<std::uint16_t>(data[4] | (data[5] << 8));
    if (version != kProtocolVersion) return false;
    const auto frame_size = static_cast<std::uint32_t>(data[8]) |
                            (static_cast<std::uint32_t>(data[9]) << 8) |
                            (static_cast<std::uint32_t>(data[10]) << 16) |
                            (static_cast<std::uint32_t>(data[11]) << 24);
    return frame_size == size;
}

}  // namespace ffb
