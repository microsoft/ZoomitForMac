import AVFoundation

/// Lightweight description of a capture device (microphone or camera).
struct CaptureDeviceInfo: Equatable {
    /// The device's unique ID, or empty for the system default.
    let id: String
    let name: String
}

/// Enumerates available microphone input devices for the recording settings.
@MainActor
enum AudioDevices {
    /// The list of selectable inputs, always led by a "Default" entry (empty id).
    static func availableMicrophones() -> [CaptureDeviceInfo] {
        var devices: [CaptureDeviceInfo] = [CaptureDeviceInfo(id: "", name: "Default")]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        for device in discovery.devices {
            devices.append(CaptureDeviceInfo(id: device.uniqueID, name: device.localizedName))
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

    static func supportsWindNoiseRemoval(deviceID: String) -> Bool {
        guard #available(macOS 15.0, *),
              let device = microphone(forID: deviceID),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        return input.isWindNoiseRemovalSupported
    }

    @discardableResult
    static func setWindNoiseRemoval(_ enabled: Bool, on input: AVCaptureDeviceInput) -> Bool {
        guard #available(macOS 15.0, *), input.isWindNoiseRemovalSupported else { return false }
        input.isWindNoiseRemovalEnabled = enabled
        return input.isWindNoiseRemovalEnabled == enabled
    }

    private static var deviceTypes: [AVCaptureDevice.DeviceType] {
        if #available(macOS 14.0, *) {
            return [.microphone, .external]
        } else {
            return [.builtInMicrophone, .externalUnknown]
        }
    }
}

/// Enumerates available camera devices for the webcam picture-in-picture.
@MainActor
enum VideoDevices {
    /// The list of selectable cameras, always led by a "Default" entry.
    static func availableCameras() -> [CaptureDeviceInfo] {
        var devices: [CaptureDeviceInfo] = [CaptureDeviceInfo(id: "", name: "Default")]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        for device in discovery.devices {
            devices.append(CaptureDeviceInfo(id: device.uniqueID, name: device.localizedName))
        }
        return devices
    }

    /// Resolves a stored device id to a concrete camera, or the default camera.
    static func camera(forID id: String) -> AVCaptureDevice? {
        if !id.isEmpty, let device = AVCaptureDevice(uniqueID: id) {
            return device
        }
        return AVCaptureDevice.default(for: .video)
    }

    private static var deviceTypes: [AVCaptureDevice.DeviceType] {
        if #available(macOS 14.0, *) {
            return [.builtInWideAngleCamera, .external, .continuityCamera]
        } else {
            return [.builtInWideAngleCamera, .externalUnknown]
        }
    }
}
