import Foundation

public struct CalculatorEvaluation: Equatable, Sendable {
    public var expression: String
    public var result: String

    public init(expression: String, result: String) {
        self.expression = expression
        self.result = result
    }
}

public enum CalculatorError: Error, Equatable, LocalizedError {
    case missingExpression
    case invalidExpression(String)
    case divisionByZero
    case unsupportedUnit(String)
    case incompatibleUnits(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingExpression:
            return "Enter something to calculate."
        case .invalidExpression(let detail):
            return "Could not calculate that expression: \(detail)"
        case .divisionByZero:
            return "Cannot divide by zero."
        case .unsupportedUnit(let unit):
            return "\(unit) is not a supported conversion unit."
        case .incompatibleUnits(let from, let to):
            return "Cannot convert \(from) to \(to)."
        }
    }
}

public struct CalculatorService: Sendable {
    public init() {}

    public func evaluate(_ rawExpression: String) throws -> CalculatorEvaluation {
        let trimmed = rawExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CalculatorError.missingExpression
        }
        let expression = SpokenArithmeticNormalizer.normalize(trimmed)

        if looksLikeConversion(expression) {
            return try evaluateConversion(expression)
        }

        var parser = ArithmeticParser(expression)
        let value = try parser.parse()
        guard value.isFinite else {
            throw CalculatorError.invalidExpression("The result is not finite.")
        }
        return CalculatorEvaluation(expression: expression, result: Self.format(value))
    }

    private func looksLikeConversion(_ expression: String) -> Bool {
        let lowered = " \(expression.lowercased()) "
        return lowered.contains(" to ") || lowered.contains(" in ")
    }

    private func evaluateConversion(_ expression: String) throws -> CalculatorEvaluation {
        let parts = expression
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
        guard parts.count == 4 else {
            throw CalculatorError.invalidExpression("Use a conversion like 10 cm to in.")
        }

        guard ["to", "in"].contains(parts[2].lowercased()) else {
            throw CalculatorError.invalidExpression("Use to or in between units.")
        }

        guard let value = Double(parts[0]) else {
            throw CalculatorError.invalidExpression("Conversion amount must be a number.")
        }

        let from = try ConversionUnit(raw: parts[1])
        let to = try ConversionUnit(raw: parts[3])
        let converted = try from.convert(value, to: to)
        return CalculatorEvaluation(
            expression: expression,
            result: "\(Self.format(converted)) \(to.displayName)"
        )
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value,
           value <= Double(Int64.max),
           value >= Double(Int64.min) {
            return String(Int64(value))
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 10
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

private enum ConversionUnit: Equatable {
    case length(UnitLength, String)
    case mass(UnitMass, String)
    case temperature(UnitTemperature, String)

    init(raw: String) throws {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "")

        switch normalized {
        case "m", "meter", "meters", "metre", "metres":
            self = .length(.meters, "m")
        case "cm", "centimeter", "centimeters", "centimetre", "centimetres":
            self = .length(.centimeters, "cm")
        case "mm", "millimeter", "millimeters", "millimetre", "millimetres":
            self = .length(.millimeters, "mm")
        case "km", "kilometer", "kilometers", "kilometre", "kilometres":
            self = .length(.kilometers, "km")
        case "in", "inch", "inches":
            self = .length(.inches, "in")
        case "ft", "foot", "feet":
            self = .length(.feet, "ft")
        case "yd", "yard", "yards":
            self = .length(.yards, "yd")
        case "mi", "mile", "miles":
            self = .length(.miles, "mi")
        case "g", "gram", "grams":
            self = .mass(.grams, "g")
        case "kg", "kilogram", "kilograms":
            self = .mass(.kilograms, "kg")
        case "lb", "lbs", "pound", "pounds":
            self = .mass(.pounds, "lb")
        case "oz", "ounce", "ounces":
            self = .mass(.ounces, "oz")
        case "c", "celsius":
            self = .temperature(.celsius, "C")
        case "f", "fahrenheit":
            self = .temperature(.fahrenheit, "F")
        case "k", "kelvin":
            self = .temperature(.kelvin, "K")
        default:
            throw CalculatorError.unsupportedUnit(raw)
        }
    }

    var displayName: String {
        switch self {
        case .length(_, let name), .mass(_, let name), .temperature(_, let name):
            return name
        }
    }

    func convert(_ value: Double, to target: ConversionUnit) throws -> Double {
        switch (self, target) {
        case let (.length(source, _), .length(destination, _)):
            return Measurement(value: value, unit: source).converted(to: destination).value
        case let (.mass(source, _), .mass(destination, _)):
            return Measurement(value: value, unit: source).converted(to: destination).value
        case let (.temperature(source, _), .temperature(destination, _)):
            return Measurement(value: value, unit: source).converted(to: destination).value
        default:
            throw CalculatorError.incompatibleUnits(displayName, target.displayName)
        }
    }
}

private struct ArithmeticParser {
    private let scalars: [UnicodeScalar]
    private var index: Int = 0

    init(_ expression: String) {
        self.scalars = Array(expression.unicodeScalars)
    }

    mutating func parse() throws -> Double {
        let value = try parseExpression()
        skipWhitespace()
        guard isAtEnd else {
            throw CalculatorError.invalidExpression("Unexpected token \(String(scalars[index])).")
        }
        return value
    }

    private mutating func parseExpression() throws -> Double {
        var value = try parseTerm()
        while true {
            skipWhitespace()
            if consume("+") {
                value += try parseTerm()
            } else if consume("-") {
                value -= try parseTerm()
            } else {
                return value
            }
        }
    }

    private mutating func parseTerm() throws -> Double {
        var value = try parseFactor()
        while true {
            skipWhitespace()
            if consume("*") {
                value *= try parseFactor()
            } else if consume("/") {
                let divisor = try parseFactor()
                guard divisor != 0 else {
                    throw CalculatorError.divisionByZero
                }
                value /= divisor
            } else {
                return value
            }
        }
    }

    private mutating func parseFactor() throws -> Double {
        skipWhitespace()
        if consume("+") {
            return try parseFactor()
        }
        if consume("-") {
            return -(try parseFactor())
        }
        if consume("(") {
            let value = try parseExpression()
            skipWhitespace()
            guard consume(")") else {
                throw CalculatorError.invalidExpression("Missing closing parenthesis.")
            }
            return value
        }
        return try parseNumber()
    }

    private mutating func parseNumber() throws -> Double {
        skipWhitespace()
        let start = index
        var hasDecimal = false
        while !isAtEnd {
            let scalar = scalars[index]
            if scalar == "." {
                guard !hasDecimal else {
                    throw CalculatorError.invalidExpression("Number has more than one decimal point.")
                }
                hasDecimal = true
                index += 1
            } else if scalar.properties.numericType != nil {
                index += 1
            } else {
                break
            }
        }

        guard index > start else {
            throw CalculatorError.invalidExpression("Expected a number.")
        }

        let text = String(String.UnicodeScalarView(scalars[start..<index]))
        guard let value = Double(text) else {
            throw CalculatorError.invalidExpression("Could not parse \(text) as a number.")
        }
        return value
    }

    private mutating func skipWhitespace() {
        while !isAtEnd, CharacterSet.whitespacesAndNewlines.contains(scalars[index]) {
            index += 1
        }
    }

    private mutating func consume(_ token: Character) -> Bool {
        guard let scalar = String(token).unicodeScalars.first,
              !isAtEnd,
              scalars[index] == scalar else {
            return false
        }
        index += 1
        return true
    }

    private var isAtEnd: Bool {
        index >= scalars.count
    }
}
