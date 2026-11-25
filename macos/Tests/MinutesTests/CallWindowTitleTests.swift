import Testing
@testable import Minutes

struct CallWindowTitleTests {
    @Test func meetingWindowWinsOverTheMainWindow() {
        let titles = ["Chat | Dana Whitfield | Microsoft Teams", "Acme quarterly review | Microsoft Teams"]
        #expect(CallWindowTitle.bestTitle(from: titles, appName: "Microsoft Teams") == "Acme quarterly review")
    }

    @Test func mainWindowAloneNamesNothing() {
        #expect(CallWindowTitle.bestTitle(from: ["Calendar | Calendar | Microsoft Teams"],
                                          appName: "Microsoft Teams") == nil)
        #expect(CallWindowTitle.bestTitle(from: ["Microsoft Teams"], appName: "Microsoft Teams") == nil)
    }

    @Test func oneToOneCallIsNamedAfterThePerson() {
        #expect(CallWindowTitle.bestTitle(from: ["Chat | General | Microsoft Teams", "Dana Whitfield | Microsoft Teams"],
                                          appName: "Microsoft Teams") == "Dana Whitfield")
    }

    @Test func genericTitlesAreIgnored() {
        #expect(CallWindowTitle.bestTitle(from: ["Zoom Meeting", "Zoom Workplace"], appName: "Zoom") == nil)
        #expect(CallWindowTitle.bestTitle(from: ["Meeting compact view | Microsoft Teams"],
                                          appName: "Microsoft Teams") == nil)
    }
}
