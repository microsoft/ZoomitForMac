import AVFoundation

/// Lightweight description of a microphone input device.
struct AudioInputDevice: Equatable {
    /// The device's unique ID, or empty for the system default input.
    let id: String
    let name: String
}

/// Enumerates available microphone input devices for the recording settings.
@MainActor
enum AudioDevices {
    /// The list of selectable inputs, always led by a "Default" entry (empty id).
    static func availableMicrophones() -> [AudioInputDevice] {
        var devices: [AudioInputDevice] = [AudioInputDevice(id: "", name: "Default")]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        for device in discovery.devices {
            devices.append(AudioInputDevice(id: device.uniqueID, name: device.localizedName))
        }
        return devices
    }

    /// Resolves a stored device id to a concrete capture device, or the default
    /// input when the id is empty or no longer present.
    static func microphone(forID id: String) -> AVCaptureDevice? {
        if !id.isEmpty, let device = AVCaptureDevice(uniqueID: id) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    private static var deviceTypes: [AVCaptureDevice.DeviceType] {
        if #available(macOS 14.0, *) {
            return [.microphone, .external]
        } else {
            return [.builtInMicrophone, .externalUnknown]
        }
    }
}
