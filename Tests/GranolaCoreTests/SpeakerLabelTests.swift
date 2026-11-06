import Testing
@testable import GranolaCore

@Suite struct SpeakerLabelTests {
    func meeting(_ attendees: [Attendee]) -> Meeting {
        Meeting(title: "Sync", attendees: attendees)
    }

    @Test func oneOtherAttendeeIsNamed() {
        let m = meeting([Attendee(name: "Agrim Singh", email: "agrim@example.com"),
                         Attendee(name: "Priya Shah", email: "priya@example.com")])
        #expect(m.otherSideLabel(userName: "Agrim Singh") == "Priya Shah")
    }

    @Test func userIsRecognisedByPartialName() {
        let m = meeting([Attendee(name: "Agrim"), Attendee(name: "Priya Shah")])
        #expect(m.otherSideLabel(userName: "Agrim Singh") == "Priya Shah")
    }

    @Test func attendeeWithoutNameFallsBackToEmail() {
        let m = meeting([Attendee(email: "priya@example.com")])
        #expect(m.otherSideLabel(userName: "Agrim Singh") == "priya@example.com")
    }

    @Test func groupUsesFirstNames() {
        let two = meeting([Attendee(name: "Priya Shah"), Attendee(name: "Marcus Lee")])
        #expect(two.otherSideLabel(userName: nil) == "Priya, Marcus")
        let four = meeting([Attendee(name: "Agrim Singh"), Attendee(name: "Priya Shah"), Attendee(name: "Marcus Lee"),
                            Attendee(name: "Dana Kim"), Attendee(name: "Lee Wong")])
        #expect(four.otherSideLabel(userName: "Agrim Singh") == "Priya, Marcus +2")
    }

    @Test func unknownAttendees() {
        #expect(meeting([]).otherSideLabel(userName: "Agrim Singh") == "Other side")
        #expect(meeting([Attendee(name: "Agrim Singh")]).otherSideLabel(userName: "Agrim Singh") == "Other side")
    }

    @Test func identifiedSpeakerWins() {
        var segment = TranscriptSegment(meetingID: "m", source: .system, text: "hi", startOffset: 0, endOffset: 1)
        #expect(segment.displaySpeaker(otherSide: "Priya Shah") == "Priya Shah")
        segment.speaker = "Speaker 2"
        #expect(segment.displaySpeaker(otherSide: "Priya Shah") == "Speaker 2")
        segment.source = .microphone
        segment.speaker = nil
        #expect(segment.displaySpeaker(otherSide: "Priya Shah") == "Me")
    }
}
