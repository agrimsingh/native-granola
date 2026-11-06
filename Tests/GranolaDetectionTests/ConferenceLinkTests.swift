import Foundation
import GranolaCore
import Testing
@testable import GranolaDetection

@Suite struct ConferenceLinkTests {
    @Test(arguments: [
        ("Join: https://zoom.us/j/1234567890?pwd=abcDEF.1", "https://zoom.us/j/1234567890?pwd=abcDEF.1", ConferenceProvider.zoom),
        ("https://us02web.zoom.us/j/86123456789?pwd=xyz", "https://us02web.zoom.us/j/86123456789?pwd=xyz", .zoom),
        ("Personal room https://acme.zoom.us/my/jane.doe.", "https://acme.zoom.us/my/jane.doe", .zoom),
        ("zoom.us/j/555", "https://zoom.us/j/555", .zoom),
        ("Join with Google Meet: https://meet.google.com/abc-defg-hij", "https://meet.google.com/abc-defg-hij", .googleMeet),
        ("meet.google.com/abc-defg-hij?authuser=1", "https://meet.google.com/abc-defg-hij?authuser=1", .googleMeet),
        ("Click here <https://teams.microsoft.com/l/meetup-join/19%3ameeting_ABC%40thread.v2/0?context=%7b%22Tid%22%7d>",
         "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ABC%40thread.v2/0?context=%7b%22Tid%22%7d", .teams),
        ("https://teams.microsoft.com/meet/2345678901234?p=abcd", "https://teams.microsoft.com/meet/2345678901234?p=abcd", .teams),
        ("https://teams.live.com/meet/9876543210", "https://teams.live.com/meet/9876543210", .teams),
        ("https://acme.webex.com/acme/j.php?MTID=m123", "https://acme.webex.com/acme/j.php?MTID=m123", .webex),
        ("https://acme.webex.com/meet/jdoe", "https://acme.webex.com/meet/jdoe", .webex),
        ("Huddle: https://app.slack.com/huddle/T0123ABC/C0456DEF", "https://app.slack.com/huddle/T0123ABC/C0456DEF", .slack),
        ("https://chime.aws/1234567890", "https://chime.aws/1234567890", .chime),
    ])
    func extractsProviderLinks(text: String, expected: String, provider: ConferenceProvider) throws {
        let url = try #require(ConferenceLinkExtractor.firstURL(in: text))
        #expect(url.absoluteString == expected)
        #expect(ConferenceLinkExtractor.provider(for: url) == provider)
    }

    @Test func ignoresNonConferenceLinks() {
        #expect(ConferenceLinkExtractor.firstURL(in: "Agenda: https://docs.google.com/document/d/123 and https://zoom.us/pricing") == nil)
        #expect(ConferenceLinkExtractor.firstURL(in: "Room 4B") == nil)
    }

    @Test func earliestLinkInTextWins() {
        let text = "Primary https://meet.google.com/aaa-bbbb-ccc backup https://zoom.us/j/1"
        #expect(ConferenceLinkExtractor.firstURL(in: text)?.host == "meet.google.com")
    }

    @Test func sourcePriorityURLThenLocationThenNotes() {
        let zoom = URL(string: "https://zoom.us/j/1")!
        let notes = "https://meet.google.com/abc-defg-hij"
        #expect(ConferenceLinkExtractor.conferenceURL(url: zoom, location: nil, notes: notes) == zoom)
        #expect(ConferenceLinkExtractor.conferenceURL(
            url: URL(string: "https://example.com/event/1"), location: "https://teams.live.com/meet/1", notes: notes
        )?.host == "teams.live.com")
        #expect(ConferenceLinkExtractor.conferenceURL(url: nil, location: "HQ", notes: notes)?.host == "meet.google.com")
        #expect(ConferenceLinkExtractor.conferenceURL(url: nil, location: nil, notes: nil) == nil)
    }

    @Test func participantEmailParsing() {
        #expect(CalendarService.email(from: URL(string: "mailto:jane@acme.com")!) == "jane@acme.com")
        #expect(CalendarService.email(from: URL(string: "MAILTO:jane@acme.com?subject=hi")!) == "jane@acme.com")
        #expect(CalendarService.email(from: URL(string: "mailto:bob%2Bwork@acme.com")!) == "bob+work@acme.com")
        #expect(CalendarService.email(from: URL(string: "urn:uuid:1234")!) == nil)
    }

    @Test func participantCountDedupesOrganizer() {
        let start = Date(timeIntervalSince1970: 0)
        var event = CalendarEvent(
            id: "e", title: " ", start: start, end: start.addingTimeInterval(60),
            attendees: [Attendee(name: "A", email: "a@x.com"), Attendee(name: "B", email: "B@x.com")]
        )
        event.organizer = Attendee(name: "Bee", email: "b@x.com")
        #expect(event.participantCount == 2)
        #expect(event.displayTitle == "Untitled meeting")
    }
}
