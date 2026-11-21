import Foundation

enum CallState: Equatable {
    case idle
    case connecting
    case ringing
    case connected
    case ended
    case failed(String)
}
