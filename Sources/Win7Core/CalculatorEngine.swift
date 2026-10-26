import Foundation

/// The arithmetic of the shell's Windows 7 Calculator, Standard mode. Windows' immediate execution:
/// no precedence (`2 + 3 × 4 =` is 20), each operator first applies the pending one; a second operator in a row
/// replaces the first; repeated `=` repeats the last operation with its second operand; `%` is that percent of the
/// first operand (`50 + 10 %` → 5, then `=` → 55); errors are Windows' texts and a digit starts over.
/// Results show up to 16 significant digits, without an exponent below 1e16, trailing zeros trimmed.
///
/// The numbers are decimal (Foundation's 38-digit `Decimal`), as Windows' own arithmetic is: `0.1 + 0.2` is exactly
/// 0.3 and `2 ÷ 3` rounds to 0.6666666666666667, where binary doubles would end in …6.
///
/// Range: `Decimal` holds magnitudes up to about 3.4e165 (a 38-digit significand × 10^127) and down to about 1e-128;
/// Windows 7's Calculator goes to 1e±10000. A result beyond 3.4e165 shows "Overflow" here (1e83 × 1e83, say), where
/// Windows 7 would still show the number. Because the exponent stops at 127, a result with few significant digits
/// overflows sooner: 1e127 shows, 1e64 × 1e64 (1e128) is already "Overflow". A result below about 1e-128 underflows.
public struct CalculatorEngine: Equatable, Sendable {
    public enum Key: Equatable, Hashable, Sendable {
        case digit(Int), point, negate
        case add, subtract, multiply, divide, equals
        case sqrt, percent, reciprocal
        case backspace, clearEntry, clear
        case memoryClear, memoryRecall, memoryStore, memoryAdd, memorySubtract
    }

    enum Operation: Equatable, Sendable { case add, subtract, multiply, divide }

    /// For repeated `=`: the last operation and its second operand.
    struct LastOperation: Equatable, Sendable {
        var op: Operation
        var operand: Decimal
    }

    public static let maxDigits = 16
    public static let divideByZero = "Cannot divide by zero"
    public static let undefined = "Result is undefined"
    public static let invalidInput = "Invalid input"
    public static let overflow = "Overflow"

    /// Thousands separators on the display (View ▸ Digit grouping).
    public var digitGrouping = false

    /// The value on the display.
    private var value: Decimal = 0
    /// The number being typed, as typed ("-12.", "0.5"); nil while the display shows a result.
    private var entry: String? = "0"
    /// A new second operand arrived since the last operator or `=` (typed, recalled, or a function's result).
    private var fresh = false
    private var accumulator: Decimal = 0
    private var pending: Operation?
    private var last: LastOperation?
    private var error: String?
    private var memory: Decimal = 0

    public init() {}

    // MARK: State

    public var isError: Bool { error != nil }
    /// The memory indicator ("M") shows while the memory holds a number other than 0.
    public var hasMemory: Bool { !memory.isZero }

    /// The display's text: an error message, the entry as typed, or the formatted value.
    public var display: String {
        if let error { return error }
        if let entry { return digitGrouping ? Self.group(entry) : entry }
        return Self.format(value, grouping: digitGrouping)
    }

    /// Edit ▸ Copy: the display as shown.
    public var copyText: String { display }

    // MARK: Keys

    public mutating func press(_ keys: [Key]) { for k in keys { press(k) } }

    public mutating func press(_ key: Key) {
        if error != nil {
            switch key {
            case .digit, .point: clearAll()
            case .clear, .clearEntry: clearAll(); return
            default: return
            }
        }
        switch key {
        case .digit(let d): type(String(min(max(d, 0), 9)))
        case .point: type(".")
        case .negate: negate()
        case .add: operate(.add)
        case .subtract: operate(.subtract)
        case .multiply: operate(.multiply)
        case .divide: operate(.divide)
        case .equals: equals()
        case .sqrt:
            if value < 0 { fail(Self.invalidInput) } else { setResult(Self.squareRoot(value)) }
        case .percent: setResult(pending != nil ? accumulator * value / 100 : 0)
        case .reciprocal:
            if value.isZero { fail(Self.divideByZero) } else { setResult(1 / value) }
        case .backspace: backspace()
        case .clearEntry:
            entry = "0"; value = 0; fresh = true
        case .clear: clearAll()
        case .memoryClear: memory = 0
        case .memoryRecall: setResult(memory)
        case .memoryStore: memory = value; entry = nil
        case .memoryAdd: memory = Self.checked(memory + value) ?? memory; entry = nil
        case .memorySubtract: memory = Self.checked(memory - value) ?? memory; entry = nil
        }
    }

    /// Edit ▸ Paste: the whole text must be one number — an optional sign, digits with an optional decimal point, an
    /// optional exponent; surrounding white space and thousands separators are ignored — or nothing is pasted and
    /// false comes back ("1-2" and "1.2.3" are not numbers). A number of up to 16 digits without an exponent becomes
    /// the entry, as if typed, so Backspace edits it; a longer one or one with an exponent becomes a result.
    @discardableResult
    public mutating func paste(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        guard let match = cleaned.wholeMatch(of: /([+-]?)([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?/) else { return false }
        let negative = match.1 == "-"
        let mantissa = String(match.2)
        if match.3 == nil, let typed = Self.entryText(negative: negative, mantissa: mantissa) {
            if error != nil { clearAll() }
            entry = typed
            value = Self.parse(typed)
            fresh = true
            return true
        }
        guard let v = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), v.isFinite, !v.isNaN else { return false }
        if error != nil { clearAll() }
        setResult(v)
        return true
    }

    /// The pasted mantissa as the entry would read had it been typed ("007" → "7", ".5" → "0.5", "-0" → "0"), or nil
    /// when it has more than 16 digits.
    private static func entryText(negative: Bool, mantissa: String) -> String? {
        let parts = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var integer = String(parts[0].drop { $0 == "0" })
        if integer.isEmpty { integer = "0" }
        let fraction = parts.count > 1 ? "." + parts[1] : ""
        let digits = integer.count + max(fraction.count - 1, 0) - (integer == "0" && !fraction.isEmpty ? 1 : 0)
        guard digits <= maxDigits else { return nil }
        let body = integer + fraction
        return negative && body != "0" ? "-" + body : body
    }

    // MARK: Operations

    private mutating func clearAll() {
        let keep = (digitGrouping, memory)
        self = CalculatorEngine()
        (digitGrouping, memory) = keep
    }

    private mutating func fail(_ message: String) {
        error = message
        pending = nil
        last = nil
        entry = nil
    }

    /// A function's (or recalled, pasted) value: the display shows it as a result, and it is the next operand.
    private mutating func setResult(_ v: Decimal) {
        guard let v = Self.checked(v) else { fail(Self.overflow); return }
        value = v
        entry = nil
        fresh = true
    }

    private mutating func type(_ c: String) {
        var text = entry ?? "0"
        if c == "." {
            if !text.contains(".") { text += "." }
        } else {
            let digitCount = text.filter(\.isNumber).count - (text.hasPrefix("0.") || text.hasPrefix("-0.") ? 1 : 0)
            if text == "0" { text = c }
            else if text == "-0" { text = "-" + c }
            else if digitCount < Self.maxDigits { text += c }
        }
        entry = text
        value = Self.parse(text)
        fresh = true
    }

    private mutating func negate() {
        if let e = entry {
            guard e != "0" else { return }
            let negated = e.hasPrefix("-") ? String(e.dropFirst()) : "-" + e
            entry = negated
            value = Self.parse(negated)
            fresh = true
        } else if !value.isZero {
            value = -value
            fresh = true
        }
    }

    private mutating func backspace() {
        guard var e = entry else { return }
        e.removeLast()
        if e.isEmpty || e == "-" || e == "-0" { e = "0" }
        entry = e
        value = Self.parse(e)
    }

    private mutating func operate(_ op: Operation) {
        if let p = pending, fresh {
            guard let r = apply(p, accumulator, value) else { return }
            accumulator = r
            value = r
        } else if pending == nil {
            accumulator = value
        }
        pending = op
        entry = nil
        fresh = false
    }

    private mutating func equals() {
        if let p = pending {
            let operand = value
            guard let r = apply(p, accumulator, operand) else { return }
            last = LastOperation(op: p, operand: operand)
            pending = nil
            accumulator = r
            value = r
        } else if let l = last {
            guard let r = apply(l.op, value, l.operand) else { return }
            accumulator = r
            value = r
        }
        entry = nil
        fresh = false
    }

    /// `a op b`, or nil after showing the error.
    private mutating func apply(_ op: Operation, _ a: Decimal, _ b: Decimal) -> Decimal? {
        let r: Decimal
        switch op {
        case .add: r = a + b
        case .subtract: r = a - b
        case .multiply: r = a * b
        case .divide:
            if b.isZero { fail(a.isZero ? Self.undefined : Self.divideByZero); return nil }
            r = a / b
        }
        guard let r = Self.checked(r) else { fail(Self.overflow); return nil }
        return r
    }

    /// `v`, with −0 as 0, or nil when it is not a number (Decimal's overflow).
    private static func checked(_ v: Decimal) -> Decimal? {
        guard v.isFinite, !v.isNaN else { return nil }
        return v.isZero ? 0 : v
    }

    private static func parse(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")).flatMap(checked) ?? 0
    }

    /// √v for v ≥ 0: the double's root, refined by Newton's method in decimal.
    static func squareRoot(_ v: Decimal) -> Decimal {
        guard v > 0 else { return 0 }
        var x = Decimal(NSDecimalNumber(decimal: v).doubleValue.squareRoot())
        if x.isZero { x = v }
        for _ in 0..<6 { x = (x + v / x) / 2 }
        return x
    }

    // MARK: Formatting

    /// Windows' number format: up to 16 significant digits, trailing zeros trimmed; an exponent ("1.e+16",
    /// "3.333333333333333e-7") from 1e16 up, and for small numbers whose digits don't fit in 16 places after the point.
    public static func format(_ x: Decimal, grouping: Bool = false) -> String {
        guard let x = checked(x) else { return overflow }
        if x.isZero { return "0" }
        var magnitude = x.magnitude
        var rounded = Decimal()
        NSDecimalRound(&rounded, &magnitude, maxDigits - 1 - decimalExponent(magnitude), .plain)
        let exponent = decimalExponent(rounded)
        var digits = rounded.significand.description
        while digits.count > 1 && digits.hasSuffix("0") { digits.removeLast() }
        let sign = x < 0 ? "-" : ""
        let leadingZeros = -exponent - 1
        if exponent >= maxDigits || (exponent < 0 && leadingZeros + digits.count > maxDigits) {
            let mantissa = String(digits.prefix(1)) + "." + String(digits.dropFirst())
            return sign + mantissa + "e" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
        }
        var text: String
        if exponent < 0 {
            text = "0." + String(repeating: "0", count: leadingZeros) + digits
        } else if digits.count <= exponent + 1 {
            text = digits + String(repeating: "0", count: exponent + 1 - digits.count)
        } else {
            let split = digits.index(digits.startIndex, offsetBy: exponent + 1)
            text = String(digits[..<split]) + "." + String(digits[split...])
        }
        if grouping { text = group(text) }
        return sign + text
    }

    /// The power of ten of `v`'s first significant digit (floor(log10 |v|)), for v ≠ 0.
    private static func decimalExponent(_ v: Decimal) -> Int {
        v.exponent + v.significand.magnitude.description.count - 1
    }

    /// Thousands separators in the integer part of a plain number ("-1234567.5" → "-1,234,567.5").
    static func group(_ text: String) -> String {
        var body = Substring(text)
        var sign = ""
        if body.hasPrefix("-") { sign = "-"; body = body.dropFirst() }
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integer = Array(parts[0])
        guard integer.count > 3, integer.allSatisfy(\.isNumber) else { return text }
        var grouped = ""
        for (i, c) in integer.enumerated() {
            if i > 0 && (integer.count - i) % 3 == 0 { grouped.append(",") }
            grouped.append(c)
        }
        return sign + grouped + (parts.count > 1 ? "." + parts[1] : "")
    }

    // MARK: Keyboard

    /// The modifier keys held with a key (Win7Shell maps NSEvent's flags onto these).
    public struct KeyModifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = KeyModifiers(rawValue: 1)
        public static let control = KeyModifiers(rawValue: 2)
        public static let option = KeyModifiers(rawValue: 4)
        public static let command = KeyModifiers(rawValue: 8)
    }

    /// The key for a key press with its modifiers: `@` is √ whatever produced it (Shift+2 on US keyboards, Option+Q
    /// on Turkish Q and German ones); Ctrl+L/R/M/P/Q are Windows 7's MC, MR, MS, M+ and M−; otherwise, with no
    /// modifier or Shift alone, the typed characters (key(forCharacters:)). Anything else is not a Calculator key.
    public static func key(characters: String?, charactersIgnoringModifiers: String?, modifiers: KeyModifiers) -> Key? {
        if characters == "@" { return .sqrt }
        if modifiers == .control {
            switch charactersIgnoringModifiers?.lowercased() {
            case "l": return .memoryClear
            case "r": return .memoryRecall
            case "m": return .memoryStore
            case "p": return .memoryAdd
            case "q": return .memorySubtract
            default: return nil
            }
        }
        guard modifiers.isSubset(of: .shift), let characters else { return nil }
        return key(forCharacters: characters)
    }

    /// The key for typed characters, as Windows 7's Calculator reads the keyboard: digits, `.` or `,`, `+ - * /`,
    /// `=` or Enter, Esc = C, Backspace, Delete = CE, `%`, `@` = √, `R` = 1/x, F9 = ±.
    public static func key(forCharacters characters: String) -> Key? {
        guard characters.unicodeScalars.count == 1, let s = characters.unicodeScalars.first else { return nil }
        switch s {
        case "0"..."9": return .digit(Int(s.value - 48))
        case ".", ",": return .point
        case "+": return .add
        case "-": return .subtract
        case "*": return .multiply
        case "/": return .divide
        case "=", "\r", "\u{3}": return .equals
        case "\u{1B}": return .clear
        case "\u{7F}", "\u{8}": return .backspace
        case "\u{F728}": return .clearEntry
        case "%": return .percent
        case "@": return .sqrt
        case "r", "R": return .reciprocal
        case "\u{F70C}": return .negate
        default: return nil
        }
    }
}
