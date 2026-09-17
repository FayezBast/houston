# Third-party assets and integration references

Provider logos are from [Lobe Icons](https://github.com/lobehub/lobe-icons), copyright 2023 LobeHub, distributed under the MIT license included at `Sources/Houston/Resources/Logos/LICENSE`. Product names and marks belong to their respective owners. Houston is not affiliated with these providers.

## SweetCookieKit 0.5.2

Browser-session import links [SweetCookieKit](https://github.com/steipete/SweetCookieKit), revision `d5ea6d92298779ec0c3ddf7d3d99da186a305e14`.

MIT License

Copyright (c) 2026 Peter Steinberger

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Integration references

The additional usage adapters were independently implemented against the documented response shapes and the following primary references:

- [Codex app-server protocol](https://developers.openai.com/codex/app-server/)
- [Claude Code status-line data](https://code.claude.com/docs/en/statusline)
- [CodexBar Copilot integration notes](https://github.com/steipete/CodexBar/blob/main/docs/copilot.md)
- [CodexBar Cursor integration notes and source](https://github.com/steipete/CodexBar/blob/main/docs/cursor.md)
- [CodexBar Gemini integration notes](https://github.com/steipete/CodexBar/blob/main/docs/gemini.md)
- [Gemini CLI project and OAuth flow](https://github.com/google-gemini/gemini-cli/tree/main/packages/core/src/code_assist)
- [CodexBar Windsurf integration notes](https://github.com/steipete/CodexBar/blob/main/docs/windsurf.md)
- [OpenRouter key usage endpoint](https://openrouter.ai/docs/api/reference/limits)
- [GitHub pull requests API](https://docs.github.com/en/rest/pulls/pulls)
- [GitHub workflow runs API](https://docs.github.com/en/rest/actions/workflow-runs)

Copilot and Gemini usage endpoints, and Windsurf's local cache schema, are provider-specific interfaces that can change. Houston reports unavailable data instead of inventing a quota.

## Sparkle

Houston embeds [Sparkle](https://github.com/sparkle-project/Sparkle), the macOS software update framework, under its BSD license. The complete upstream license is included as `Contents/Resources/Sparkle-LICENSE` in distributed builds.
