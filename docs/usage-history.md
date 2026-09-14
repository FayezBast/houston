# Usage history and quota alerts

Houston records successful live usage readings while it is running. History is local to this Mac and starts when Houston receives its first reading; it does not import an account's earlier activity. **Usage → History** offers 7-day and 30-day views with separate provider, account and allowance-window selectors.

## What is stored

`~/Library/Application Support/Houston/usage-history.json` contains timestamps, provider names, account identifiers and labels, window names, percentage use, reset times, and reported API currency amounts when available. It contains no prompts, transcripts or credentials. Stored account identifiers distinguish sign-ins; an account whose identity cannot be established is excluded from persistent history. Saved additional accounts use their Houston account UUID.

Retention is bounded by both 90 days and 100,000 samples across all accounts. Busy installations can reach the sample cap sooner. Removing an account connection does not retroactively delete its observed history. History writes are atomic; an unreadable archive is preserved before collection resumes. If that backup cannot be made, recording pauses.

Readings more than 10 minutes old, expired allowance windows, duplicate timestamps and readings older than the latest observation for the same series are excluded. Failed refreshes are excluded. Repeated successful reads with newer timestamps can appear even when their reported usage is unchanged. Houston does not reconstruct what happened while it was closed, offline, or missing a fresh provider response. Chart lines break across reset cycles and observation gaps longer than 15 minutes; intermediate values are not additional measurements.

## Percentages and money

Subscription charts show the percentage of that particular allowance window used. They are not token counts, usage volume comparisons between plans, or dollar totals. OpenRouter budget percentages are labeled as API budget use, and its reported spend appears in a separate currency series. Currency amounts are never clamped to 100 or converted between currencies. A missing budget is not a zero budget.

For spending, “Observed increase” is the difference between the first and last readings in the selected period, shown only when that series does not decrease. It is limited to the sampled interval and is not an invoice or a complete calendar-period total.

“Exhausted windows observed” counts distinct reported reset cycles where Houston saw 100% used. With no reset time, it counts an observed transition into exhaustion. Unobserved limits are not counted, so these counts can be lower than the number of limits actually reached.

## Alerts and pace

Tools contains separate low-quota and reset notification switches and a remaining-percentage threshold. macOS notification permission is required for banners. A first reading establishes a silent baseline. A later crossing from above the threshold to at or below it can alert once for the same account, window and reported reset cycle. Without a reset time, that series has no verified new cycle to rearm its warning during the retained history.

A reset alert requires a fresh reading with a later reset deadline after the previous deadline has passed. A countdown reaching zero, a usage decrease, or a future deadline correction alone does not trigger a reset alert. Houston cannot guarantee notification at the instant a provider resets; it must first receive an updated reading.

The pace estimate uses increasing observations in the same known reset cycle from the latest six hours, with at least two readings spanning five minutes. The latest reading must be no more than 10 minutes old and its reset deadline must still be in the future. Decreases, insufficient history, missing reset times, and stale readings suppress the estimate. It projects the observed percentage-use rate to exhaustion and compares that time with reset. This is a linear estimate of recent behavior, not a promise of future capacity or a guess at plan token limits.

## Visual checks

`FeatureRenderTests` uses temporary account, agent and history data and isolated notification preferences. Set `HOUSTON_RENDER_DIR` when running the tests to save light, dark and narrow feature screenshots plus expanded navigation renders. These fixtures do not install agent hooks or save credentials to Keychain.
