import Testing
import Foundation
@testable import Win7Core

// The shell's Windows 7 Calculator, Standard mode, immediate execution.

private typealias K = CalculatorEngine.Key

/// The engine after pressing `keys` from a fresh start.
private func run(_ keys: [K]) -> CalculatorEngine {
    var e = CalculatorEngine()
    e.press(keys)
    return e
}

private func digits(_ s: String) -> [K] {
    s.map { $0 == "." ? K.point : K.digit(Int(String($0))!) }
}

@Suite struct CalculatorEngineTests {
    @Test func startsAtZero() {
        let e = CalculatorEngine()
        #expect(e.display == "0" && !e.hasMemory && !e.isError)
    }

    /// No precedence: each operator applies the pending one first.
    @Test func immediateExecution() {
        let e = run([.digit(2), .add, .digit(3), .multiply])
        #expect(e.display == "5")
        #expect(run([.digit(2), .add, .digit(3), .multiply, .digit(4), .equals]).display == "20")
        #expect(run(digits("10") + [.subtract] + digits("4") + [.divide, .digit(2), .equals]).display == "3")
    }

    @Test func divisionByZero() {
        let e = run([.digit(5), .divide, .digit(0), .equals])
        #expect(e.isError && e.display == "Cannot divide by zero")
        #expect(run([.digit(0), .reciprocal]).display == "Cannot divide by zero")
        // 0 ÷ 0 is Windows 7's other message.
        #expect(run([.digit(0), .divide, .digit(0), .equals]).display == "Result is undefined")
        // A chained operator reports it too.
        #expect(run([.digit(5), .divide, .digit(0), .add]).display == "Cannot divide by zero")
    }

    @Test func afterAnErrorDigitsStartOverAndOperatorsAreIgnored() {
        var e = run([.digit(5), .divide, .digit(0), .equals])
        e.press([.add, .sqrt, .memoryStore])
        #expect(e.display == "Cannot divide by zero" && !e.hasMemory)
        e.press(.digit(7))
        #expect(e.display == "7" && !e.isError)
        e.press([.add, .digit(1), .equals])
        #expect(e.display == "8")
        var c = run([.digit(5), .divide, .digit(0), .equals])
        c.press(.clearEntry)
        #expect(c.display == "0" && !c.isError)
    }

    @Test func squareRoot() {
        #expect(run([.digit(9), .sqrt]).display == "3")
        #expect(run([.digit(2), .sqrt]).display == "1.414213562373095")
        #expect(run([.digit(9), .negate, .sqrt]).display == "Invalid input")
        // The result is the operand of the pending operation.
        #expect(run([.digit(1), .add, .digit(9), .sqrt, .equals]).display == "4")
    }

    /// Windows: percent of the first operand.
    @Test func percent() {
        let e = run(digits("50") + [.add] + digits("10") + [.percent])
        #expect(e.display == "5")
        #expect(run(digits("50") + [.add] + digits("10") + [.percent, .equals]).display == "55")
        #expect(run(digits("200") + [.multiply] + digits("10") + [.percent, .equals]).display == "4000")
        // With nothing pending there is no first operand: 0.
        #expect(run(digits("10") + [.percent]).display == "0")
    }

    @Test func reciprocal() {
        #expect(run([.digit(4), .reciprocal]).display == "0.25")
        #expect(run([.digit(8), .reciprocal, .reciprocal]).display == "8")
    }

    @Test func negate() {
        #expect(run([.digit(5), .negate]).display == "-5")
        #expect(run([.digit(5), .negate, .negate]).display == "5")
        // While typing, the sign goes on the entry, and typing continues.
        #expect(run([.digit(1), .digit(2), .negate, .digit(3)]).display == "-123")
        #expect(run([.negate]).display == "0")
        // On a result it negates the result; the next digit starts a new number.
        var e = run([.digit(2), .add, .digit(3), .equals, .negate])
        #expect(e.display == "-5")
        e.press(.digit(4))
        #expect(e.display == "4")
        #expect(run([.digit(7), .subtract, .digit(2), .negate, .equals]).display == "9")
    }

    /// Repeated = repeats the last operation with its second operand.
    @Test func repeatEquals() {
        var e = run([.digit(2), .add, .digit(3), .equals])
        #expect(e.display == "5")
        e.press(.equals)
        #expect(e.display == "8")
        e.press(.equals)
        #expect(e.display == "11")
        #expect(run(digits("10") + [.subtract, .digit(2), .equals, .equals]).display == "6")
        #expect(run([.digit(3), .multiply, .equals]).display == "9")   // `3 × =`: the display is the operand
        // A new number then = applies the last operation to it.
        #expect(run([.digit(2), .add, .digit(3), .equals, .digit(7), .equals]).display == "10")
        // = with nothing pending or remembered leaves the number.
        #expect(run([.digit(4), .equals]).display == "4")
    }

    @Test func operatorPressedTwiceReplacesTheFirst() {
        #expect(run([.digit(2), .add, .multiply, .digit(3), .equals]).display == "6")
        // After =, an operator works on the result.
        #expect(run([.digit(2), .add, .digit(3), .equals, .multiply, .digit(2), .equals]).display == "10")
    }

    @Test func backspace() {
        var e = run(digits("123"))
        e.press(.backspace)
        #expect(e.display == "12")
        e.press([.backspace, .backspace])
        #expect(e.display == "0")
        e.press(.backspace)
        #expect(e.display == "0")
        #expect(run(digits("1.5") + [.backspace]).display == "1.")
        #expect(run([.digit(5), .negate, .backspace]).display == "0")
        // A result is not an entry: Backspace leaves it.
        #expect(run([.digit(2), .add, .digit(3), .equals, .backspace]).display == "5")
    }

    @Test func clearEntryAndClear() {
        #expect(run([.digit(2), .add, .digit(3), .clearEntry, .digit(4), .equals]).display == "6")
        #expect(run([.digit(2), .add, .digit(3), .clearEntry]).display == "0")
        var e = run([.digit(2), .add, .digit(3), .memoryStore, .clear])
        #expect(e.display == "0" && e.hasMemory)   // C keeps the memory
        e.press([.digit(4), .equals])
        #expect(e.display == "4")                   // and forgets the pending and the last operation
    }

    @Test func memory() {
        var e = run([.digit(5), .memoryStore])
        #expect(e.hasMemory && e.display == "5")
        e.press([.clear, .memoryRecall])
        #expect(e.display == "5")
        e.press([.digit(3), .memoryAdd, .memoryRecall])
        #expect(e.display == "8")
        e.press([.digit(2), .memorySubtract, .memoryRecall])
        #expect(e.display == "6")
        e.press(.memoryClear)
        #expect(!e.hasMemory)
        e.press(.memoryRecall)
        #expect(e.display == "0")
        // MS ends the entry: the next digit starts a new number; MR's value is an operand.
        var f = run([.digit(4), .memoryStore, .digit(2)])
        #expect(f.display == "2")
        f.press([.add, .memoryRecall, .equals])
        #expect(f.display == "6")
    }

    @Test func formatting() {
        #expect(run(digits("0.1") + [.add] + digits("0.2") + [.equals]).display == "0.3")
        #expect(run([.digit(1), .divide, .digit(3), .equals]).display == "0.3333333333333333")
        #expect(run([.digit(2), .divide, .digit(3), .equals]).display == "0.6666666666666667")
        #expect(CalculatorEngine.format(1234.5) == "1234.5")
        #expect(CalculatorEngine.format(-0.0) == "0")
        #expect(CalculatorEngine.format(1e15) == "1000000000000000")
        #expect(CalculatorEngine.format(1234567890123456) == "1234567890123456")
        #expect(CalculatorEngine.format(1.0 / 3_000_000) == "3.333333333333333e-7")
        #expect(CalculatorEngine.format(0.0000001) == "0.0000001")
        #expect(CalculatorEngine.format(1e16) == "1.e+16")
        #expect(CalculatorEngine.format(-2.5e20) == "-2.5e+20")
        #expect(CalculatorEngine.format(0.000125) == "0.000125")
        #expect(CalculatorEngine.format(Decimal(string: "1e-20")!) == "1.e-20")
        #expect(CalculatorEngine.format(1234567.5, grouping: true) == "1,234,567.5")
        #expect(CalculatorEngine.format(-1234, grouping: true) == "-1,234")
        #expect(CalculatorEngine.format(999, grouping: true) == "999")
    }

    /// Foundation's Decimal reaches about 3.4e165 at most (Windows 7: 1e±10000; see CalculatorEngine's header):
    /// 1e83 squared (1e166) is beyond that range and is "Overflow". 1e127 still shows.
    @Test func overflow() {
        var e = CalculatorEngine()
        var ok = e.paste("1e63"); #expect(ok)
        e.press([.multiply])
        ok = e.paste("1e64"); #expect(ok)
        e.press(.equals)
        #expect(e.display == "1.e+127")
        #expect(!e.isError)
        // A round number past the 127 exponent overflows below 3.4e165.
        e.press([.multiply, .digit(1), .digit(0), .equals])
        #expect(e.display == "Overflow")
        e = CalculatorEngine()
        ok = e.paste("1e83"); #expect(ok)
        e.press([.multiply, .equals])
        #expect(e.display == "Overflow" && e.isError)
    }

    @Test func entry() {
        #expect(run([.point, .digit(5)]).display == "0.5")
        #expect(run([.digit(1), .point, .point, .digit(2)]).display == "1.2")
        #expect(run([.digit(0), .digit(0), .digit(7)]).display == "7")
        // Up to 16 digits.
        #expect(run(digits("12345678901234567")).display == "1234567890123456")
        #expect(run(digits("0.12345678901234567")).display == "0.1234567890123456")
        // Digit grouping applies to the entry too.
        var e = run(digits("1234567.25"))
        e.digitGrouping = true
        #expect(e.display == "1,234,567.25")
        e.press([.add, .digit(1), .equals])
        #expect(e.display == "1,234,568.25")
    }

    @Test func copyAndPaste() {
        var e = CalculatorEngine()
        let pasted = e.paste(" 1,234.5\n")
        #expect(pasted)
        #expect(e.display == "1234.5")
        e.press([.add, .digit(1), .equals])
        #expect(e.display == "1235.5")
        let rejected = ["abc", "", "inf", "nan", "0x1p3"].map { e.paste($0) }
        #expect(rejected == [false, false, false, false, false])
        #expect(e.display == "1235.5")
        e.digitGrouping = true
        #expect(e.copyText == "1,235.5")
        #expect(run([.digit(5), .divide, .digit(0), .equals]).copyText == "Cannot divide by zero")
    }

    /// Paste takes the whole text as one number (sign, decimals, digit groups, an exponent) or nothing at all.
    @Test func pasteParsesTheWholeNumber() {
        func pasted(_ text: String) -> String? {
            var e = CalculatorEngine()
            e.press(.digit(7))
            return e.paste(text) ? e.display : nil
        }
        #expect(pasted("-12.5") == "-12.5")
        #expect(pasted("+3") == "3")
        #expect(pasted(".5") == "0.5")
        #expect(pasted("007") == "7")
        #expect(pasted("1,234,567") == "1234567")
        #expect(pasted("2.5e3") == "2500")
        for bad in ["1-2", "1.2.3", "--1", "1e", "e5", "-", ".", "1+", "12abc", "1 2"] {
            #expect(pasted(bad) == nil, "\(bad)")
        }
        // Rejected text changes nothing.
        var e = CalculatorEngine()
        e.press(.digit(7))
        let ok = e.paste("1-2"); #expect(!ok)
        #expect(e.display == "7")
    }

    /// A pasted number of up to 16 digits is an entry, as if typed: Backspace edits it and digits extend it.
    @Test func backspaceEditsAPastedNumber() {
        var e = CalculatorEngine()
        var ok = e.paste("1234.5"); #expect(ok)
        e.press(.backspace)
        #expect(e.display == "1234.")
        e.press([.backspace, .backspace])
        #expect(e.display == "123")
        e.press(.digit(9))
        #expect(e.display == "1239")
        e.press([.add, .digit(1), .equals])
        #expect(e.display == "1240")
        ok = e.paste("-5"); #expect(ok)
        e.press(.backspace)
        #expect(e.display == "0")
        // Longer than 16 digits, or with an exponent: a result (rounded), which Backspace leaves alone.
        ok = e.paste("12345678901234567"); #expect(ok)
        e.press(.backspace)
        #expect(e.display == "1.234567890123457e+16")
        ok = e.paste("2e3"); #expect(ok)
        e.press(.backspace)
        #expect(e.display == "2000")
    }

    /// The Windows 7 keyboard: digits, operators, Enter/=, Esc = C, Backspace, Delete = CE, @ = √, R = 1/x, F9 = ±.
    @Test func keyboard() {
        let map = CalculatorEngine.key(forCharacters:)
        #expect(map("7") == .digit(7) && map("0") == .digit(0))
        #expect(map(".") == .point && map(",") == .point)
        #expect(map("+") == .add && map("-") == .subtract && map("*") == .multiply && map("/") == .divide)
        #expect(map("=") == .equals && map("\r") == .equals && map("\u{3}") == .equals)
        #expect(map("\u{1B}") == .clear)
        #expect(map("\u{7F}") == .backspace && map("\u{8}") == .backspace)
        #expect(map("\u{F728}") == .clearEntry)   // NSDeleteFunctionKey (forward delete)
        #expect(map("%") == .percent && map("@") == .sqrt && map("r") == .reciprocal && map("R") == .reciprocal)
        #expect(map("\u{F70C}") == .negate)       // NSF9FunctionKey
        #expect(map("a") == nil && map("") == nil && map("12") == nil)
    }

    /// With modifiers: `@` is √ however it is typed (Option+Q on Turkish Q and German layouts, Shift+2 on US), the
    /// Windows 7 memory shortcuts Ctrl+L/R/M/P/Q, and Shift still types `+ * %`. Other combinations are not keys.
    @Test func keyboardWithModifiers() {
        typealias M = CalculatorEngine.KeyModifiers
        func key(_ chars: String, _ plain: String? = nil, _ mods: M) -> CalculatorEngine.Key? {
            CalculatorEngine.key(characters: chars, charactersIgnoringModifiers: plain ?? chars, modifiers: mods)
        }
        #expect(key("@", "q", [.option]) == .sqrt)
        #expect(key("@", "2", [.shift]) == .sqrt)
        #expect(key("@", "q", [.option, .shift]) == .sqrt)
        #expect(key("\u{C}", "l", [.control]) == .memoryClear)
        #expect(key("\u{12}", "r", [.control]) == .memoryRecall)
        #expect(key("\r", "m", [.control]) == .memoryStore)
        #expect(key("\u{10}", "p", [.control]) == .memoryAdd)
        #expect(key("\u{11}", "q", [.control]) == .memorySubtract)
        #expect(key("\u{12}", "R", [.control, .shift]) == nil)
        #expect(key("+", "=", [.shift]) == .add && key("7", nil, []) == .digit(7))
        #expect(key("l", nil, [.command]) == nil && key("r", nil, [.command]) == nil)
        #expect(key("7", nil, [.option]) == nil && key("r", nil, [.control, .option]) == nil)
    }
}
