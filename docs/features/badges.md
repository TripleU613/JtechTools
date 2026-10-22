# Badges for Jtech's tools

Badges anyone can earn by taking part in what Jtech adds: elections, REQ-PM, the for-sale thread, Dumbcourse and pop-ups. They sit beside Discourse's own on `/badges`, each set in its own group, and come and go with their module: switching a module off switches its badges off.

They're seeded like core's (by name, on every rebuild), so rename or reword one under **Customize → Text** (`badges.<name>.name`, `.description`, `.long_description`), not in the badge editor. Discourse's daily badge run grants them; election badges also arrive as soon as nominations close and when results are published.

## Elections

| Badge | Tier | Granted for |
| --- | --- | --- |
| Constituent | Bronze | You voted in a moderator election, once its results are published. It shows that you voted, never how, and not whether your ballot was set aside. |
| Civic Duty | Silver | You voted in three elections. |
| Candidate | Bronze | You were on the ballot when nominations closed, whether you stayed in or not. |
| Stepped Aside | Bronze | You dropped out of an election. |
| Runner-up | Bronze | You were on the ballot at the published count but didn't win a seat. |
| Elected | Gold | You won a seat. |
| Re-elected | Gold | You won seats in two elections. |
| Former Moderator | Silver | The staff log shows you were made a moderator, elected or appointed, and you aren't one now. Taken back if you become a moderator again. Moderators are public while they serve (the about page, their flair), so this shows nothing that wasn't. |

Nobody taken off a ballot gets Candidate, and only published results count towards Runner-up and Elected.

## REQ-PM

| Badge | Tier | Granted for |
| --- | --- | --- |
| Business Card | Bronze | You added a contact method to your card. |
| Connected | Bronze | You shared your details with someone. Nobody can see who with. |
| Networker | Silver | You've shared your details with five different people. |

## The for-sale thread

Listings are posts after the opening one in the topics in `listing_format_topics`, unlisted (archived) sale threads included; changing that setting rebuilds these badges' queries.

| Badge | Tier | Granted for |
| --- | --- | --- |
| Seller | Bronze | Your first listing. |
| First Sale | Bronze | One of your listings was marked sold. |
| Merchant | Silver | Five listings. |
| Trader | Gold | Ten listings. |

## Dumbcourse

Dumbcourse counts the days a signed-in member opens it (user fields `dumbcourse_days` and `dumbcourse_last_day`, in UTC) and marks posts written in its composer (post field `dumbcourse`).

| Badge | Tier | Granted for |
| --- | --- | --- |
| Flip Phone | Bronze | You opened Dumbcourse while signed in. |
| Keypad Regular | Silver | You opened it on 30 different days. |
| T9 Typist | Bronze | Your first post or topic written in Dumbcourse. |
| T9 Master | Gold | A hundred posts written in Dumbcourse. |

## Across the tools

| Badge | Tier | Granted for |
| --- | --- | --- |
| Heads Up | Bronze | You turned on desktop pop-ups (Preferences → Account). In Getting Started. |
| Power User | Gold | You hold Constituent, Business Card, Seller, Flip Phone and Heads Up. In Community; on whenever Jtech is. |
