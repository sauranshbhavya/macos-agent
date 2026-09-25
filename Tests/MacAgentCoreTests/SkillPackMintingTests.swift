import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// **A flow that mints a credential does not load** (SONNY-534), held in both directions and by
/// value, through the real decoder wherever a row says what the loader does.
///
/// The measurement this rests on over the shipped packs lives in `SkillPackTests`, because only that
/// file may read the shipped folder: `theMintingTestIsMeasuredOverTheShippedTextsThatNameAKeyOrAToken`.
@Suite
struct SkillPackMintingTests {
    /// review-278's probe, by value: Google Cloud's own steps from "Create and delete service account
    /// keys", written the way a lane would write them. At `856bb7ee` every one of these six texts
    /// loaded, and so did the flow.
    static let googleCloudTitle = "Create a service account key"
    static let googleCloudSteps = [
        "In the Google Cloud console, go to the Service accounts page and select a project.",
        "Click the email address of the service account that you want to create a key for.",
        "Click the Keys tab.",
        "Click the Add key drop-down menu, then select Create new key.",
        "Select JSON as the Key type and click Create. Clicking Create downloads a service account key file."
    ]

    @Test
    func theGoogleCloudServiceAccountKeyFlowDoesNotLoad() throws {
        var object = SkillPackFixtures.object(id: "google_cloud", name: "Google Cloud", domain: "cloud.google.com", category: "developer_platforms")
        object["flows"] = [SkillPackFixtures.flow(title: Self.googleCloudTitle, steps: Self.googleCloudSteps, on: "cloud.google.com")]
        object["startPages"] = [SkillPackFixtures.startPage(on: "cloud.google.com")]
        #expect(SkillPackTests.error(object) == .mentionsCredential(field: "flows.title", phrase: "service account key"))

        // Line by line, so that the flow is not refused on its title alone: a lane that titled it
        // "Set up a service account" would still meet three refusals. The two lines that load are
        // navigation, which is SONNY-510's stop-step ruling to judge and not this rule's.
        let perLine = ([Self.googleCloudTitle] + Self.googleCloudSteps).map(SkillPackCredentialRule.violation(in:))
        #expect(perLine == ["service account key", nil, "create + key", nil, "add + key", "service account key"])
    }

    /// **Each row names the word that fires**, for review-268's F2 reason: a row that refuses for some
    /// other entry hides a dead one. Deleting any one `mintingWords` entry, any one `mintedObjects`
    /// entry or any one SONNY-534 phrase turns exactly the rows that name it red.
    @Test
    func aStepThatMintsAKeyOrATokenDoesNotLoad() throws {
        let rows: [(step: String, phrase: String)] = [
            // `mintingWords`, one row each.
            ("Click Create restricted key.", "create + key"),
            ("Creating a key downloads it to your computer.", "creating + key"),
            // `and` is not a linking word, deliberately: two verbs share the one object.
            ("Generate and download the key.", "generate + key"),
            ("Generating tokens signs the old ones out.", "generating + tokens"),
            ("Click Regenerate key.", "regenerate + key"),
            ("Regenerating a key disables the old one.", "regenerating + key"),
            ("Rotate the signing key.", "rotate + key"),
            ("Rotating keys is done on the same page.", "rotating + keys"),
            ("Click Roll key.", "roll + key"),
            ("Rolling a key blocks the old one after the expiry you choose.", "rolling + key"),
            ("Click Add key, then pick JSON.", "add + key"),
            ("Adding a key takes a moment.", "adding + key"),
            ("Click New token.", "new + token"),
            // review-285's F6: the three of its verbs that joined, base and "-ing" form each.
            ("Click Reset key.", "reset + key"),
            ("Resetting the key signs every client out.", "resetting + key"),
            ("Click Reissue token.", "reissue + token"),
            // No article, because "a token" is an older phrase and the older refusal keeps its word.
            ("Reissuing tokens invalidates the old ones.", "reissuing + tokens"),
            ("Recreate the key after the rotation.", "recreate + key"),
            ("Recreating a key takes a minute.", "recreating + key"),
            // The other two pages review-278 measured loading: AWS's, which is a phrase now, and
            // DigitalOcean's, where the nearest minting word to the object is the one named.
            ("In the Access keys section, choose Create access key.", "access key"),
            ("Click Generate New Token, enter a name and choose an expiry.", "new + token"),
            // The object need not be beside the word: whatever names the key sits between them.
            ("Click the email address of the service account that you want to create a key for.", "create + key"),
            ("Create a new production signing key named deploy.", "new + key"),
            // The SONNY-534 phrases, which refuse wherever they stand, navigation included.
            ("Open the Access keys section.", "access keys"),
            ("Download the service account key.", "service account key"),
            ("List the project's service account keys.", "service account keys"),
            ("Click New SSH key.", "ssh key"),
            ("Open SSH keys.", "ssh keys"),
            ("Add a deploy key.", "deploy key"),
            ("Open Deploy keys.", "deploy keys"),
            ("Choose Create key pair.", "key pair"),
            ("Open Key Pairs.", "key pairs")
        ]
        for row in rows {
            var object = SkillPackFixtures.object()
            object["flows"] = [SkillPackFixtures.flow(steps: ["Open the page.", row.step])]
            #expect(
                SkillPackTests.error(object) == .mentionsCredential(field: "flows.steps", phrase: row.phrase),
                "\(row.step) → \(String(describing: SkillPackTests.error(object)))"
            )
        }
    }

    /// **A text the rule refused before SONNY-534 is refused on the word it always was.** The minting
    /// test runs last, so it can only add a refusal to a text that had none.
    @Test
    func anOlderRefusalKeepsItsWord() throws {
        #expect(SkillPackCredentialRule.violation(in: "Click Create API key.") == "api key")
        #expect(SkillPackCredentialRule.violation(in: "Click Create new secret key.") == "secret")
        #expect(SkillPackCredentialRule.violation(in: "Create a personal access token") == "access token")
        #expect(SkillPackCredentialRule.violation(in: "Click Generate Token, then copy the token, which is shown once.") == "the token")
        #expect(SkillPackCredentialRule.violation(in: "Create a new key and type your PIN.") == "PIN")
    }

    /// **The word `key` in every sense a shipped pack uses it, and the shapes the three conditions
    /// exist for** — the other side of the table above.
    ///
    /// The first eleven rows are shipped steps at `856bb7ee`, quoted rather than paraphrased: every
    /// text the credential rule reads that holds `key`, `keys`, `token` or `tokens` as a whole word,
    /// less one. The one left out is Segment's, "these might be a key or token issued by the
    /// destination tool", which also loads and is the only one of the twelve that means a credential;
    /// it is reported on SONNY-534 rather than pinned here as a sense that ought to load.
    ///
    /// The rest hold the conditions one at a time. Each `linkingWords` entry has a row only it frees:
    /// delete the entry and that row turns red, naming it.
    @Test
    func aKeyThatIsNotACredentialStillLoads() throws {
        let shipped: [String] = [
            "The Overview tab opens by default and summarizes the campaign's key results.",
            "Find the call whose recording you want and use the arrow key to open that caller's timeline.",
            "Type a search query, combining key:value pairs such as status:error with full-text search. Autocomplete suggests keys, values, recent searches and saved views.",
            "Open the campaign and go to its Analytics tab to see key metrics, including Sequence started, Open Rate, Click Rate, and Reply Rate.",
            "Enter a unique, human-readable Name. A key is suggested from it; click Edit key to change it now, because a saved flag key cannot be modified.",
            "When the sequence and Lead list are ready, go to the Launch tab and click Launch for X leads to open the launch recap. Review the key details there, such as how many leads will be contacted, the time between each lead and the sending schedule, then click Launch campaign for X leads to confirm and start sending.",
            "Build and deploy the site again for the addition to take effect. A variable with the same key set in a netlify.toml file overrides the one set in the Netlify UI.",
            "For a bulk update of existing partners, supply a valid partner_key or the primary partner_email of an existing partner. Updating a partner's tags will add the tag to the partner, and will not overwrite or remove existing tags.",
            "Enter the flag key your code uses to evaluate the flag, and a description.",
            "You can also drag the issue's card on the Kanban Board, or press the S key while the issue is open to change its status.",
            "Provide a Key and Value for each new environment variable."
        ]
        let conditions: [(what: String, step: String)] = [
            ("the minting word comes after the object", "Press the C key to create a card."),
            ("the same, with the object in an earlier clause", "Enter a name and a flag key, then click Create flag."),
            ("a full stop ends the clause", "Click Create. Press the S key to change its status."),
            ("a comma ends the clause", "Click New, the S key toggles the sidebar."),
            ("linking word: to", "Add a note to the key account."),
            ("linking word: for", "Create a reminder for the key date."),
            ("linking word: with", "Create a table with a partition key."),
            ("linking word: of", "Generate a report of key metrics."),
            ("linking word: in", "Add the value in the key column."),
            ("linking word: on", "Add a comment on the key frame."),
            ("linking word: by", "Create a view sorted by key."),
            ("linking word: from", "Create a chart from the key metrics."),
            ("linking word: then", "Click Create then enter a key for the flag."),
            ("an ordinary token with no minting word", "Use the design token for spacing."),
            // Why `issue` is not a minting word (review-285's F6): Jira's every issue carries one.
            ("Jira's issue key", "Enter the issue key, such as PROJ-12.")
        ]
        for step in shipped + conditions.map(\.step) {
            var object = SkillPackFixtures.object()
            object["flows"] = [SkillPackFixtures.flow(steps: ["Open the page.", step])]
            #expect(SkillPackTests.error(object) == nil, "refused: \(step) → \(String(describing: SkillPackTests.error(object)))")
        }
        // The control on the rows above: each condition's row is refused once its condition is
        // taken away, so none of them loads for a reason other than the one it is named for.
        let withoutTheCondition: [(step: String, phrase: String)] = [
            ("Create a card key.", "create + key"),
            ("Click Create flag key.", "create + key"),
            ("Click Create the S key.", "create + key"),
            ("Add a note key account.", "add + key"),
            ("Create a reminder key date.", "create + key"),
            ("Create a table partition key.", "create + key"),
            ("Generate a report key metrics.", "generate + key"),
            ("Add the value key column.", "add + key"),
            ("Add a comment key frame.", "add + key"),
            ("Create a view sorted key.", "create + key"),
            ("Create a chart key metrics.", "create + key"),
            ("Click Create enter a key.", "create + key")
        ]
        for row in withoutTheCondition {
            #expect(SkillPackCredentialRule.violation(in: row.step) == row.phrase, "\(row.step)")
        }
    }

    /// **What the minting test refuses although it is not a credential**, held so that freeing one is
    /// done on purpose and so the doc comment on `SkillPackCredentialRule` that names their kinds
    /// cannot drift from what the loader does. None is in a shipped pack. Each waits for a lane to measure
    /// the real control, the way Pinterest's "Keep board secret" was measured before `secret` was
    /// excused (SONNY-508), and joins SONNY-514's question when one does.
    @Test
    func knownRefusalsOfTheMintingTestAreHeld() throws {
        let rows: [(step: String, phrase: String)] = [
            // `key` as an adjective, in a control's own name: goal-setting tools call it a key result.
            ("Click Add key result.", "add + key"),
            // The key of a key and value, behind a hyphen, which ends the clause at `key`.
            ("Add a key-value pair.", "add + key"),
            // A design token is a named style value.
            ("Create a design token for spacing.", "create + token"),
            // A language model's output length.
            ("Set Max new tokens to 512.", "new + tokens"),
            // The price of leaving `and` off `linkingWords`.
            ("Click Create flag and enter a key for it.", "create + key"),
            // The branch's own review, F3: a database's keys, where `key` heads its phrase exactly as a
            // credential does, and a keyboard shortcut by its other name.
            ("Create a primary key for the table.", "create + key"),
            ("Add a foreign key constraint.", "add + key"),
            ("Create a new hot key.", "new + key")
        ]
        for row in rows {
            #expect(SkillPackCredentialRule.violation(in: row.step) == row.phrase, "\(row.step)")
        }
    }

    /// **What the minting test cannot see, kept here so nobody concludes it can.** Each loads. The
    /// first is left alone on purpose — reading a key that already exists is the founders' stop-step
    /// ruling of 2026-09-19 on SONNY-510 to judge, from where the flow ends — and the rest are the
    /// limits of reading words in order. If one of these goes red the rule has grown: change this
    /// test and `SkillPackCredentialRule`'s doc comment together.
    @Test
    func theMintingTestCannotSeeWhatItsDocCommentSaysItCannot() throws {
        for step in [
            "Click Reveal test key.",
            "Click the Keys tab.",
            "A key is then created.",
            "Make a key.",
            "Click Create.",
            // The branch's own review, F4 to F6. The object named first and a bare minting word after
            // it, which is how a page reached through its menus is often written; reading this shape
            // was weighed and left, because "Enter a flag key, then click Create." is the same shape
            // and is a feature-flag tool's honest step. Then a key with a number on it, which is one
            // word, and a hyphen, which ends a clause between the minting word and its object.
            "Open Account Settings, then Tokens, and click Create.",
            "Click Rotate key1.",
            "Run the create-key command.",
            // review-285's F6: the minting verbs that stay off the list, and why. `issue`, because
            // Jira's every issue carries an "issue key" — the row that loads for that reason is in
            // `aKeyThatIsNotACredentialStillLoads`; `set up`, because its first word is the verb every
            // settings step uses; the rest because they are the class "Make a key." stands for. And a
            // purpose clause behind a linking word, which `to` frees on purpose.
            "Click Issue token.",
            "Set up a signing key.",
            "Refresh the key.",
            "Provision a key.",
            "Register a security key.",
            "Click Create to get your key."
        ] {
            #expect(SkillPackCredentialRule.violation(in: step) == nil, "the rule has grown: \(step)")
        }
    }
}
