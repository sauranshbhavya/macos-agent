import Foundation
import Testing
@testable import MacAgent

struct TaskGreetingFormatterTests {
    @Test(arguments: [
        (4, "Night"),
        (5, "Morning"),
        (11, "Morning"),
        (12, "Afternoon"),
        (16, "Afternoon"),
        (17, "Evening"),
        (21, "Evening"),
        (22, "Night"),
        (23, "Night"),
        (0, "Night")
    ])
    func greetingUsesTheCorrectTimeOfDayPeriod(hour: Int, expectedPeriod: String) {
        let greeting = TaskGreetingFormatter.greeting(hour: hour, fullName: "", displayFullNames: false)
        #expect(greeting == "Good \(expectedPeriod)")
    }

    @Test
    func emptyFullNameOmitsTheNameEntirely() {
        let greeting = TaskGreetingFormatter.greeting(hour: 9, fullName: "", displayFullNames: true)
        #expect(greeting == "Good Morning")
    }

    @Test
    func displayFullNamesOffShowsOnlyTheFirstName() {
        let greeting = TaskGreetingFormatter.greeting(hour: 9, fullName: "Sauransh Bhardwaj", displayFullNames: false)
        #expect(greeting == "Good Morning, Sauransh")
    }

    @Test
    func displayFullNamesOnShowsTheWholeName() {
        let greeting = TaskGreetingFormatter.greeting(hour: 9, fullName: "Sauransh Bhardwaj", displayFullNames: true)
        #expect(greeting == "Good Morning, Sauransh Bhardwaj")
    }

    @Test
    func singleWordNameIsUnaffectedByTheDisplayFullNamesToggle() {
        let shortForm = TaskGreetingFormatter.greeting(hour: 9, fullName: "Sonny", displayFullNames: false)
        let fullForm = TaskGreetingFormatter.greeting(hour: 9, fullName: "Sonny", displayFullNames: true)
        #expect(shortForm == "Good Morning, Sonny")
        #expect(fullForm == "Good Morning, Sonny")
    }
}
