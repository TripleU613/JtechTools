# Marketplace accounts

Marketplace members can trade without posting or returning to the forum. They
must not lose sign-in access to their orders because core considers them inactive.

Enable **Market accounts** in Admin → Plugins → Jtech Tools. A successful,
signed DiscourseConnect provider sign-in to the configured marketplace callback
sets a private server-owned `jtech_market_account` user field. Members cannot
edit it through profile preferences. The core inactive-user cleanup query then
excludes those users in one subquery. Other inactive accounts are still cleaned
according to `clean_up_inactive_users_after_days`; its value is never changed.

| Setting | Default | Effect |
| --- | --- | --- |
| `jtech_market_account_retention` | false | Protect marketplace-linked users while `jtech_enabled` is on. |
| `jtech_market_origin` | `https://market.jtechforums.org` | Exact HTTPS origin allowed to establish protection; callback path is `/api/v1/auth/discourse/callback`. |

For members linked before installing this feature, backfill only forum IDs
verified against the marketplace's `accounts` table using
`DiscourseMarketAccounts.protect!(user)`. Do not mark users based on a link click
or a claimed email address. Disabling the feature stops the exclusion but keeps
the fields for a subsequent re-enable. Explicit member/staff deletion and other
core moderation are unchanged.
