import Testing

// RefinementOutputGuard.swift is compiled directly into this bundle: the guard
// is pure Foundation, so the tests need no app host.

struct GuardCase: CustomTestStringConvertible, Sendable {
    let name: String
    let raw: String
    let refined: String
    var snippetExpandedRaw: String? = nil
    var dictionaryTerms: [String] = []

    var testDescription: String { name }

    func rejection() -> RefinementOutputGuard.Rejection? {
        RefinementOutputGuard.rejection(
            for: refined,
            raw: raw,
            snippetExpandedRaw: snippetExpandedRaw,
            dictionaryTerms: dictionaryTerms
        )
    }
}

/// Correct cleanups. Every one of these is something the prompt's rules ask
/// for; rejecting it silently inserts the raw transcript instead.
@Test(arguments: [
    GuardCase(
        name: "punctuation and filler removal",
        raw: "um so the deploy failed because the uh the database migration timed out and we need to rerun it",
        refined: "The deploy failed because the database migration timed out, and we need to rerun it."
    ),
    GuardCase(
        name: "rule 1 fillers like / you know / I mean",
        raw: "like i mean it's kind of like you know fine by me honestly",
        refined: "It's fine by me, honestly."
    ),
    GuardCase(
        name: "rule 2 backtrack discards most of the utterance",
        raw: "tell sarah the meeting moved to the big conference room on the third floor no wait scratch that tell john",
        refined: "Tell John."
    ),
    GuardCase(
        name: "rule 2 inline correction",
        raw: "let's meet at two actually three",
        refined: "Let's meet at 3."
    ),
    GuardCase(
        name: "rule 4 spoken punctuation",
        raw: "hey john comma can you send the report new paragraph thanks",
        refined: "Hey John,\n\nCan you send the report?\n\nThanks"
    ),
    GuardCase(
        name: "rule 7 dictionary sound-alikes",
        raw: "push the fix to get hub and then ping cloud about the new build",
        refined: "Push the fix to GitHub and then ping Claude about the new build.",
        dictionaryTerms: ["GitHub", "Claude"]
    ),
    GuardCase(
        name: "rule 8 money and dates",
        raw: "it costs three hundred dollars on january fifteenth twenty twenty six",
        refined: "It costs $300 on January 15, 2026."
    ),
    GuardCase(
        name: "rule 8 times",
        raw: "call me at five thirty p m tomorrow about the quarterly numbers",
        refined: "Call me at 5:30 PM tomorrow about the quarterly numbers."
    ),
    GuardCase(
        name: "dictated reply that starts with sure",
        raw: "sure um i can do that tomorrow morning",
        refined: "Sure, I can do that tomorrow morning."
    ),
    GuardCase(
        name: "dictated here's",
        raw: "okay here is the plan for the launch next week",
        refined: "Okay, here's the plan for the launch next week."
    ),
    GuardCase(
        name: "question kept as a question",
        raw: "um so what's the difference between tcp and udp and like when would i use each one",
        refined: "What's the difference between TCP and UDP, and when would I use each one?"
    ),
    GuardCase(
        name: "compose request kept as a sentence",
        raw: "can you write a short email to my manager saying i'll be out on friday",
        refined: "Can you write a short email to my manager saying I'll be out on Friday?"
    ),
    GuardCase(
        name: "question followed by the speaker's own statement",
        raw: "what do you think? i think we should ship it",
        refined: "What do you think? I think we should ship it."
    ),
    GuardCase(
        name: "spurious Whisper question mark removed",
        raw: "I was wondering if you could send the deck over?",
        refined: "I was wondering if you could send the deck over."
    ),
    GuardCase(
        name: "statement starting with what",
        raw: "what i'm saying is we should ship the release on thursday",
        refined: "What I'm saying is we should ship the release on Thursday."
    ),
    GuardCase(
        name: "compound joined",
        raw: "send me the web site link by e mail when you get a chance",
        refined: "Send me the website link by email when you get a chance."
    ),
    GuardCase(
        name: "snippet cue expanded by the model",
        raw: "thanks book time here my cal link and let me know",
        refined: "Thanks! Book time here: https://cal.com/example/30min and let me know.",
        snippetExpandedRaw: "thanks book time here https://cal.com/example/30min and let me know"
    ),
    GuardCase(
        name: "snippet cue left literal by the model",
        raw: "thanks here's my cal link",
        refined: "Thanks, here's my cal link.",
        snippetExpandedRaw: "thanks here's Book a slot with me any weekday afternoon at https://cal.com/example/30min"
    ),
    GuardCase(
        name: "long snippet body with clipboard placeholder",
        raw: "sig",
        refined: "Best regards,\nJane Doe\nStaff Engineer, Example Corp\n{{clipboard}}\nPlease consider the environment before printing this email. This message and any attachments are confidential and intended only for the named recipient.",
        snippetExpandedRaw: "Best regards,\nJane Doe\nStaff Engineer, Example Corp\n{{clipboard}}\nPlease consider the environment before printing this email. This message and any attachments are confidential and intended only for the named recipient."
    )
])
func acceptsFaithfulCleanup(_ testCase: GuardCase) {
    #expect(testCase.rejection() == nil)
}

/// Generated content the speaker never said.
@Test(arguments: [
    (GuardCase(
        name: "assistant preamble",
        raw: "can you do that tomorrow morning",
        refined: "Sure, I can do that tomorrow morning."
    ), RefinementOutputGuard.Rejection.assistantPreamble),
    (GuardCase(
        name: "short answer appended to question",
        raw: "what's the capital of france",
        refined: "What's the capital of France? Paris."
    ), .questionWasAnswered),
    (GuardCase(
        name: "email appended to compose question",
        raw: "can you write a short email to my manager saying i'll be out on friday",
        refined: "Can you write a short email to my manager saying I'll be out on Friday? Subject: Out of office Friday. Hi, I wanted to let you know I will be taking a personal day this Friday. Thanks."
    ), .questionWasAnswered),
    (GuardCase(
        name: "question replaced by declarative answer",
        raw: "what is the difference between tcp and udp",
        refined: "TCP is connection-oriented and reliable, while UDP is connectionless and faster."
    ), .questionWasAnswered),
    (GuardCase(
        name: "unpunctuated question answered with yes",
        raw: "is it going to rain in seattle this weekend",
        refined: "Yes, expect showers on Saturday."
    ), .questionWasAnswered),
    (GuardCase(
        name: "compose command fulfilled",
        raw: "write a short email to my manager saying i'll be out on friday",
        refined: "Subject: Out of office Friday\n\nHi,\n\nI wanted to let you know I will be taking a personal day this Friday.\n\nThanks"
    ), .contentWasReplaced),
    (GuardCase(
        name: "compose command fulfilled while echoing it",
        raw: "draft a slack message telling the team the launch moved to next week",
        refined: "Draft a Slack message telling the team the launch moved to next week: Hey everyone, heads up that we are pushing the launch back while we finish testing."
    ), .contentWasAdded),
    (GuardCase(
        name: "paragraph summarised",
        raw: "so we talked about the roadmap and the hiring plan and uh the budget for next quarter and we agreed that marketing gets more money and engineering hires two people",
        refined: "Summary: roadmap, hiring and budget discussed."
    ), .contentWasReplaced),
    (GuardCase(
        name: "runaway expansion",
        raw: "give me some ideas for a team offsite",
        refined: "Give me some ideas for a team offsite. Options include a cooking class where everyone prepares a meal together, a guided hike followed by a picnic lunch, an escape room challenge, a volunteering afternoon at a local food bank, or a workshop on improvisation."
    ), .runawayExpansion),
    (GuardCase(
        name: "snippet present does not disable the guard",
        raw: "what's the capital of france my cal link",
        refined: "What's the capital of France? Paris. https://cal.com/example/30min",
        snippetExpandedRaw: "what's the capital of france https://cal.com/example/30min"
    ), .questionWasAnswered)
])
func rejectsGeneratedContent(_ testCase: GuardCase, expected: RefinementOutputGuard.Rejection) {
    #expect(testCase.rejection() == expected)
}
