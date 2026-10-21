import Foundation
import CoreAudio

/// Наблюдатель за изменениями списка аудиоустройств (подключение/отключение
/// USB-интерфейсов). Использует HAL listener на kAudioHardwarePropertyDevices.
public final class AudioDeviceChangeObserver: @unchecked Sendable {

    private let callback: () -> Void
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var isActive = false

    public init(_ callback: @escaping () -> Void) {
        self.callback = callback
        startListening()
    }

    public func cancel() {
        guard isActive else { return }
        var address = PropertyAddress.address(
            kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        if let listenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                nil,
                listenerBlock
            )
        }
        listenerBlock = nil
        isActive = false
    }

    deinit {
        cancel()
    }

    private func startListening() {
        var address = PropertyAddress.address(
            kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )

        let block: @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.callback()
            }
        }
        self.listenerBlock = block

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        isActive = status == noErr
    }
}