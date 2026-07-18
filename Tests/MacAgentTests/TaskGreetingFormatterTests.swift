import Foundation
import Testing
@testable import MacAgent

struct TaskGreetingFormatterTests {
    @Test(arguments: [
        (4, "night"),
        (5, "morning"),
        (11, "morning"),
        (12, "afternoon"),
        (16, "afternoon"),
        (17, "evening"),
        (21, "evening"),
        (22, "night"),
        (23, "night"),
        (0, "night")
    ])
    func greetingUsesTheCorrectTimeOfDayPeriod(hour: Int, expectedPeriod: String) {
        let greeting = TaskGreetingFormatter.greeting(hour: hour, fullName: "", displayFullNames: false)
        #expect(greeting == "Good \(expectedPeriod)")
    }

    @Test
    func emptyFullNameOmitsTheNameEntirely() {
        let greeting = TaskGreetingFormatter.greeting(hour: 9, fullName: "", displayFullNames: true)
        #expect(greeting == "Good morning")
    }

    @Test
    func displayFullNamesOffShowsOnlyTheFirstName() {
        let greeting = TaskGreetingFormatter.greeting(hour: 9, fullName: "Sauransh Bhardwaj", displayFullNames: false)
        #expect(greeting == "Good morning, Sauransh")
    }

    @Test
    func displayFullNamesOnShowsTheWholeName() {
        let greeting = TaskGreetingFormatter.greeting(hour: 9, fullName: "Sauransh Bhardwaj", displayFullNames: true)
        #expect(greeting == "Good morning, Sauransh Bhardwaj")
    }

    @Test
    func singleWordNameIsUnaffectedByTheDisplayFullNamesToggle() {
        let shortForm = TaskGreetingFormatter.greeting(hour: 9, fullName: "Sonny", displayFullNames: false)
        let fullForm = TaskGreetingFormatter.greeting(hour: 9, fullName: "Sonny", displayFullNames: true)
        #expect(shortForm == "Good morning, Sonny")
        #expect(fullForm == "Good morning, Sonny")
    }
}
