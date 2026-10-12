import Foundation

/// Limits the sky to chosen airlines or flights, matched against the broadcast (ICAO) callsign.
///
/// Users may type ICAO airline codes ("UAL"), IATA codes ("UA", "MU", "3U"), ICAO callsigns
/// ("UAL1577") or IATA flight numbers ("UA1577"). IATA codes are turned into ICAO codes with a
/// lookup the caller supplies, because aircraft broadcast ICAO callsigns.
public struct FlightFilter: Equatable, Sendable {
    public enum Token: Equatable, Hashable, Sendable {
        /// ICAO airline designator, e.g. "UAL".
        case airline(String)
        /// Exact ICAO callsign, e.g. "UAL1577".
        case callsign(String)
    }

    public var tokens: Set<Token>

    public init(tokens: Set<Token>) { self.tokens = tokens }

    public func matches(_ a: Aircraft) -> Bool {
        guard let cs = a.callsign?.uppercased().replacingOccurrences(of: " ", with: ""), !cs.isEmpty else { return false }
        for t in tokens {
            switch t {
            case .callsign(let c):
                if cs == c { return true }
            case .airline(let icao):
                // "UAL" matches "UAL1577" but not "UALX" style private callsigns of other operators.
                if cs.hasPrefix(icao), cs.count > icao.count,
                   cs[cs.index(cs.startIndex, offsetBy: icao.count)].isNumber { return true }
            }
        }
        return false
    }

    /// One entry the user typed, classified.
    public enum Entry: Equatable, Sendable {
        case icaoAirline(String)
        case icaoCallsign(String)
        case iataAirline(String)
        case iataFlight(airline: String, number: String)
        case invalid(String)
    }

    public static func split(_ text: String) -> [String] {
        text.uppercased()
            .components(separatedBy: CharacterSet(charactersIn: ",，、;；/ \n\t"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func classify(_ raw: String) -> Entry {
        let s = raw.uppercased()
        let letters = CharacterSet.uppercaseLetters
        func allLetters(_ x: Substring) -> Bool { x.unicodeScalars.allSatisfy { letters.contains($0) } }
        func isAlnum(_ x: Substring) -> Bool { x.unicodeScalars.allSatisfy { letters.contains($0) || CharacterSet.decimalDigits.contains($0) } }
        guard !s.isEmpty, s.count <= 8, isAlnum(Substring(s)) else { return .invalid(raw) }
        if s.count == 3, allLetters(Substring(s)) { return .icaoAirline(s) }
        if s.count == 2 { return .iataAirline(s) }
        // ICAO callsign: three letters followed by a flight number (digits, optional trailing letters).
        if s.count > 3, allLetters(s.prefix(3)), s.dropFirst(3).first?.isNumber == true { return .icaoCallsign(s) }
        // IATA flight number: two-character airline code, then digits (optional suffix letter).
        if s.count > 2, s.dropFirst(2).first?.isNumber == true {
            let digits = s.dropFirst(2)
            return .iataFlight(airline: String(s.prefix(2)), number: String(digits.drop { $0 == "0" }.isEmpty ? digits : digits.drop { $0 == "0" }))
        }
        if allLetters(Substring(s)) { return .icaoCallsign(s) }
        return .invalid(raw)
    }

    /// Builds a filter. `iataToICAO` maps IATA airline codes to every ICAO code they may stand for;
    /// entries whose IATA code is missing from it are reported in `unresolved`.
    public static func build(from text: String, iataToICAO: [String: [String]]) -> (filter: FlightFilter, unresolved: [String], invalid: [String]) {
        var tokens = Set<Token>()
        var unresolved: [String] = [], invalid: [String] = []
        for raw in split(text) {
            switch classify(raw) {
            case .icaoAirline(let c): tokens.insert(.airline(c))
            case .icaoCallsign(let c): tokens.insert(.callsign(c))
            case .iataAirline(let c):
                if let icaos = iataToICAO[c], !icaos.isEmpty { icaos.forEach { tokens.insert(.airline($0)) } }
                else { unresolved.append(raw) }
            case .iataFlight(let a, let n):
                if let icaos = iataToICAO[a], !icaos.isEmpty { icaos.forEach { tokens.insert(.callsign($0 + n)) } }
                else { unresolved.append(raw) }
            case .invalid(let r): invalid.append(r)
            }
        }
        return (FlightFilter(tokens: tokens), unresolved, invalid)
    }

    /// IATA airline codes the text refers to (to resolve before calling `build`).
    public static func iataCodes(in text: String) -> Set<String> {
        var out = Set<String>()
        for raw in split(text) {
            switch classify(raw) {
            case .iataAirline(let c): out.insert(c)
            case .iataFlight(let a, _): out.insert(a)
            default: break
            }
        }
        return out
    }
}
