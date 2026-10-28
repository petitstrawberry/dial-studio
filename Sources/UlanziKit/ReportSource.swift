import Foundation

/// Where raw HID reports come from: the device directly, or the root helper
/// that owns the device exclusively.
public protocol ReportSource: AnyObject {
    var onReport: ((RawReport) -> Void)? { get set }
    var onConnectionChange: ((Bool) -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }
    func start()
    func stop()
}
