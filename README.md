# reddit_filter
[![Hex.pm](https://img.shields.io/hexpm/v/reddit_filter.svg)](https://hex.pm/packages/reddit_filter)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/reddit_filter)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE.md)

em_filter agent for Reddit using the public JSON API.

Combines two complementary search modes running in parallel:

- **Subreddit listing** — fetches hot/new/top/rising posts from configured subreddits and filters by keyword. No authentication required.
- **Global search** — uses Reddit's search endpoint across all of Reddit or restricted to configured subreddits.

No API key needed. Reddit requires a descriptive `User-Agent` header — this is handled automatically.

## Setup

Rename `reddit_config.json.sample` to `reddit_config.json` and configure your subreddits:

```json
{
    "subreddits": [
        "erlang",
        "programming",
        "linux"
    ],
    "search_reddit": true,
    "listing": "hot"
}
```

`listing` accepts: `hot`, `new`, `top`, `rising`.

Set `search_reddit` to `false` to disable global search and only scan the configured subreddits.

## Usage

Add `reddit_filter` to your dependencies, then start it as an OTP application.
It registers itself with `em_disco` automatically on startup.

For a topic-specific filter, create a wrapper application that copies its own
`priv/reddit_config.json` to the working directory before starting `reddit_filter`.
