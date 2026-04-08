//
//  CoreHIDMouseDriver.swift
//  Moonlight for macOS
//

import CoreHID
import Foundation
import IOKit.hidsystem

@objc protocol CoreHIDMouseDriverDelegate: AnyObject {
  func coreHIDMouseDriver(_ driver: CoreHIDMouseDriver, didReceiveDeltaX deltaX: Double, deltaY: Double)
  func coreHIDMouseDriver(_ driver: CoreHIDMouseDriver, didFailWithReason reason: String, messageKey: String)
}

@objcMembers
final class CoreHIDMouseDriver: NSObject {
  private enum Failure {
    static let unsupportedOSReason = "unsupported-os"
    static let permissionDeniedReason = "permission-denied"
    static let managerErrorReason = "manager-error"
    static let clientErrorReason = "client-error"

    static let unsupportedOSMessageKey = "CoreHID Mouse requires macOS 15 or later."
    static let permissionDeniedMessageKey =
      "CoreHID Mouse access denied. Allow Input Monitoring in System Settings."
    static let runtimeErrorMessageKey = "CoreHID Mouse input failed."
  }

  weak var delegate: CoreHIDMouseDriverDelegate?

  private let stateLock = NSLock()
  private var managerTask: Task<Void, Never>?
  private var hasPostedFailure = false

  func start() {
    stop()

    guard #available(macOS 15.0, *) else {
      postFailureIfNeeded(
        reason: Failure.unsupportedOSReason,
        messageKey: Failure.unsupportedOSMessageKey
      )
      return
    }

    guard ensureListenAccessGranted() else {
      postFailureIfNeeded(
        reason: Failure.permissionDeniedReason,
        messageKey: Failure.permissionDeniedMessageKey
      )
      return
    }

    managerTask = Task { [weak self] in
      guard let self else { return }
      await self.monitorManager()
    }
  }

  func stop() {
    stateLock.lock()
    managerTask?.cancel()
    managerTask = nil
    hasPostedFailure = false
    stateLock.unlock()
  }

  deinit {
    stop()
  }

  private func ensureListenAccessGranted() -> Bool {
    let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    switch access {
    case kIOHIDAccessTypeGranted:
      return true
    case kIOHIDAccessTypeUnknown:
      return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    default:
      return false
    }
  }

  @available(macOS 15.0, *)
  private func monitorManager() async {
    let manager = HIDDeviceManager()
    let anyCriteria = HIDDeviceManager.DeviceMatchingCriteria()

    do {
      let stream = await manager.monitorNotifications(matchingCriteria: [anyCriteria])
      var clientTasks: [HIDDeviceClient.DeviceReference: Task<Void, Never>] = [:]
      defer {
        for task in clientTasks.values {
          task.cancel()
        }
      }

      for try await notification in stream {
        if Task.isCancelled {
          break
        }

        switch notification {
        case .deviceMatched(let deviceReference):
          guard clientTasks[deviceReference] == nil else {
            continue
          }

          guard let client = HIDDeviceClient(deviceReference: deviceReference) else {
            continue
          }

          clientTasks[deviceReference] = Task { [weak self] in
            guard let self else { return }
            await self.monitorClient(client)
          }

        case .deviceRemoved(let deviceReference):
          clientTasks[deviceReference]?.cancel()
          clientTasks.removeValue(forKey: deviceReference)

        @unknown default:
          continue
        }
      }
    } catch {
      if !Task.isCancelled {
        postFailureIfNeeded(
          reason: Failure.managerErrorReason,
          messageKey: Failure.runtimeErrorMessageKey
        )
      }
    }
  }

  @available(macOS 15.0, *)
  private func monitorClient(_ client: HIDDeviceClient) async {
    let movementElements = await client.elements.filter { element in
      isMovementUsage(element.usage)
    }
    guard !movementElements.isEmpty else {
      return
    }

    let emptyReportIDs: [ClosedRange<HIDReportID>] = []

    do {
      let stream = await client.monitorNotifications(
        reportIDsToMonitor: emptyReportIDs,
        elementsToMonitor: movementElements
      )

      for try await notification in stream {
        if Task.isCancelled {
          break
        }

        switch notification {
        case .elementUpdates(let values):
          var deltaX = 0.0
          var deltaY = 0.0

          for value in values {
            switch value.element.usage {
            case .genericDesktop(.x):
              deltaX += valueAsDelta(value)
            case .genericDesktop(.y):
              deltaY += valueAsDelta(value)
            default:
              continue
            }
          }

          if deltaX != 0 || deltaY != 0 {
            delegate?.coreHIDMouseDriver(self, didReceiveDeltaX: deltaX, deltaY: deltaY)
          }

        case .deviceRemoved:
          return

        case .inputReport, .deviceSeized, .deviceUnseized:
          continue

        @unknown default:
          continue
        }
      }
    } catch {
      if !Task.isCancelled {
        postFailureIfNeeded(
          reason: Failure.clientErrorReason,
          messageKey: Failure.runtimeErrorMessageKey
        )
      }
    }
  }

  @available(macOS 15.0, *)
  private func valueAsDelta(_ value: HIDElement.Value) -> Double {
    if let logicalValue = value.logicalValue(asTypeTruncatingIfNeeded: Int64.self) {
      return Double(logicalValue)
    }
    return Double(value.integerValue(asTypeTruncatingIfNeeded: Int64.self))
  }

  @available(macOS 15.0, *)
  private func isMovementUsage(_ usage: HIDUsage) -> Bool {
    if case .genericDesktop(.x) = usage {
      return true
    }
    if case .genericDesktop(.y) = usage {
      return true
    }
    return false
  }

  private func postFailureIfNeeded(reason: String, messageKey: String) {
    stateLock.lock()
    if hasPostedFailure {
      stateLock.unlock()
      return
    }
    hasPostedFailure = true
    stateLock.unlock()

    delegate?.coreHIDMouseDriver(self, didFailWithReason: reason, messageKey: messageKey)
  }
}
