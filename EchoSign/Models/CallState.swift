import Foundation

enum CallState: Equatable {
    case idle
    case connecting
    case connected
    case ended
    case failed(String)
}