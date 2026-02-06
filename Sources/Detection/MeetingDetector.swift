import Foundation

protocol MeetingDetector: AnyObject, Sendable {
    var isEnabled: Bool { get }
    func start()
    func stop()
}
