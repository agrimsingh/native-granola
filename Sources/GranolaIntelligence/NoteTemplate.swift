import Foundation

/// Shapes the enhanced notes for a type of meeting. Codable so the app can persist custom templates.
public struct NoteTemplate: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    /// Extra prompt guidance specific to this meeting type.
    public var instructions: String
    /// `###` section headers, in order.
    public var sections: [String]

    public init(id: String, name: String, description: String, instructions: String, sections: [String]) {
        self.id = id
        self.name = name
        self.description = description
        self.instructions = instructions
        self.sections = sections
    }

    public static let defaultID = "general"

    public static var `default`: NoteTemplate { general }

    /// Looks up a built-in template by id.
    public static func named(_ id: String) -> NoteTemplate? {
        builtIn.first { $0.id == id }
    }

    /// Looks up `id` in `custom` first, then built-ins, falling back to the default template.
    public static func resolve(_ id: String?, custom: [NoteTemplate] = []) -> NoteTemplate {
        guard let id else { return .default }
        return custom.first { $0.id == id } ?? named(id) ?? .default
    }

    public static let builtIn: [NoteTemplate] = [
        general, oneOnOne, salesCall, standup, interview, customerDiscovery, teamMeeting,
    ]

    public static let general = NoteTemplate(
        id: "general",
        name: "General",
        description: "Works for any meeting: summary, topics discussed, decisions and next steps.",
        instructions: """
            Start with a 1–3 bullet summary of the purpose and outcome of the meeting. \
            For "Discussion Topics", do not write a header with that literal name: instead write one `###` header \
            per main topic, named after the topic itself (e.g. "### Q3 Pricing Changes"), ordered as discussed, \
            with the key points as bullets under each.
            """,
        sections: ["Summary", "Discussion Topics", "Decisions", "Action Items"]
    )

    public static let oneOnOne = NoteTemplate(
        id: "one-on-one",
        name: "1:1",
        description: "Manager / report one-on-one: updates, feedback, blockers, growth.",
        instructions: """
            Focus on the relationship and the person: progress updates, wins, concerns, blockers, feedback given in \
            either direction, and career or growth topics. Capture feedback faithfully and neutrally. Keep personal \
            or sensitive remarks brief and factual.
            """,
        sections: ["Updates", "Wins", "Challenges & Blockers", "Feedback", "Growth & Career", "Action Items"]
    )

    public static let salesCall = NoteTemplate(
        id: "sales-call",
        name: "Sales Call",
        description: "Prospect calls: pain points, requirements, objections, budget, timeline, next steps.",
        instructions: """
            Write from the seller's perspective ("Me" is usually on the selling side). Capture the prospect's \
            company context, current solution, pain points in their own words, requirements, objections and how they \
            were handled, budget, decision makers and process, timeline, competitors mentioned, and the agreed next \
            step with dates. Quote memorable customer phrases verbatim in quotation marks when useful.
            """,
        sections: [
            "Company & Context", "Pain Points", "Requirements", "Objections & Concerns",
            "Budget, Timeline & Decision Process", "Competition", "Next Steps",
        ]
    )

    public static let standup = NoteTemplate(
        id: "standup",
        name: "Standup",
        description: "Daily standup: what each person did, will do, and blockers.",
        instructions: """
            Be very brief. Group updates by person when names can be determined (use "Me" / the user's name for the \
            user's own update); otherwise group by workstream. Highlight blockers and who can unblock them.
            """,
        sections: ["Updates", "Blockers", "Action Items"]
    )

    public static let interview = NoteTemplate(
        id: "interview",
        name: "Interview (Candidate)",
        description: "Hiring interview: candidate background, answers, strengths, concerns.",
        instructions: """
            The user is the interviewer; "Them" is the candidate. Summarize the candidate's background, the questions \
            asked with the substance of their answers, demonstrated skills with concrete evidence, strengths, \
            concerns or gaps, and the candidate's own questions. Stay objective and evidence-based; do not give a \
            hiring recommendation unless the user's notes contain one.
            """,
        sections: [
            "Candidate Background", "Questions & Answers", "Strengths", "Concerns", "Candidate Questions", "Next Steps",
        ]
    )

    public static let customerDiscovery = NoteTemplate(
        id: "customer-discovery",
        name: "Customer Discovery",
        description: "User research / discovery: workflows, problems, needs, quotes, insights.",
        instructions: """
            Focus on learning about the customer: who they are, their current workflow and tools, problems and how \
            painful they are, workarounds, what they've tried, needs and desired outcomes. Include notable verbatim \
            quotes in quotation marks. Separate what the customer said from interpretations; label inferred insights \
            as such.
            """,
        sections: [
            "Customer Profile", "Current Workflow", "Problems & Pain Points", "Needs & Desired Outcomes",
            "Notable Quotes", "Insights", "Follow-ups",
        ]
    )

    public static let teamMeeting = NoteTemplate(
        id: "team-meeting",
        name: "Team Meeting",
        description: "Recurring team sync: announcements, project updates, discussion, decisions.",
        instructions: """
            Capture announcements, the status of each project or workstream discussed (on track / at risk, with \
            reasons), discussion points with the main viewpoints, and every decision made. For "Project Updates", \
            use a bolded project name followed by its status bullets.
            """,
        sections: ["Announcements", "Project Updates", "Discussion", "Decisions", "Action Items"]
    )
}
