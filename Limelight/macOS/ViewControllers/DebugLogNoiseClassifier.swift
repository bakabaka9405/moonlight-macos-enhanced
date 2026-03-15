import Foundation

enum DebugNoiseCategory: String, CaseIterable {
  case appKitMenuInconsistency
  case networkStackNoise
  case systemTransportFallback

  var displayName: String {
    switch self {
    case .appKitMenuInconsistency:
      return "AppKit 菜单噪音 / AppKit Menu Inconsistency"
    case .networkStackNoise:
      return "系统网络噪音 / Network Stack Noise"
    case .systemTransportFallback:
      return "系统传输回退噪音 / System Transport Fallback"
    }
  }
}

enum DebugLogNoiseClassifier {
  static func category(for line: String) -> DebugNoiseCategory? {
    if line.localizedCaseInsensitiveContains("Internal inconsistency in menus") {
      return .appKitMenuInconsistency
    }

    if line.localizedCaseInsensitiveContains("NSURLErrorDomain")
      && (line.contains("-1001") || line.contains("-1004") || line.contains("-1005"))
    {
      return .systemTransportFallback
    }

    if line.localizedCaseInsensitiveContains("nw_")
      || line.localizedCaseInsensitiveContains("tcp_input")
      || line.localizedCaseInsensitiveContains("Request failed with error")
      || (line.localizedCaseInsensitiveContains("Connection ")
        && line.localizedCaseInsensitiveContains("failed"))
      || (line.localizedCaseInsensitiveContains("Task <")
        && line.localizedCaseInsensitiveContains("finished with error"))
    {
      return .networkStackNoise
    }

    return nil
  }

  static func extractErrorCodeDescription(from line: String) -> String {
    if let code = firstMatch(in: line, pattern: #"Code=(-?\d+)"#) {
      return "error \(code)"
    }
    if let code = firstMatch(in: line, pattern: #"(-1001|-1004|-1005)"#) {
      return "error \(code)"
    }
    return "error unknown"
  }

  static func extractTarget(from line: String) -> String {
    if let endpoint = firstMatch(in: line, pattern: #"((?:\d{1,3}\.){3}\d{1,3}:\d+)"#) {
      return endpoint
    }
    if let endpoint = firstMatch(in: line, pattern: #"(\[[0-9a-fA-F:]+\]:\d+)"#) {
      return endpoint
    }
    if let host = firstMatch(in: line, pattern: #"https?://([^\s/]+)"#) {
      return host
    }
    return "unknown target"
  }

  private static func firstMatch(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else {
      return nil
    }
    let captureIndex = match.numberOfRanges > 1 ? 1 : 0
    let captureRange = match.range(at: captureIndex)
    guard
      let swiftRange = Range(captureRange, in: text),
      !swiftRange.isEmpty
    else {
      return nil
    }
    return String(text[swiftRange])
  }
}
